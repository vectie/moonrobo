///|
struct DistributedSettings {
  rank : Int32
  world_size : Int32
  id_file : String
  session_id : String
  timeout_ms : Int32
  data_ready_timeout_seconds : Int32?
} derive(ToJson)

///|
fn distributed_settings(
  config : Json,
  args : Array[String],
) -> DistributedSettings? raise {
  let requested = args.contains("--distributed") ||
    setting(config, "distributed", false) ||
    [
      "--rank", "--world-size", "--nccl-id-file", "--session-id", "--nccl-timeout-ms",
      "--data-ready-timeout-seconds",
    ].any(name => args.contains(name))
  if !requested {
    return None
  }
  guard option(args, "--resume") is None else {
    fail(
      "native distributed resume is unsupported: rank-local optimizer/replay/physics generations need joint verification",
    )
  }
  let rank = @string.parse_int(required(args, "--rank"))
  let world_size = @string.parse_int(required(args, "--world-size"))
  guard world_size == 2 && rank >= 0 && rank < world_size else {
    fail(
      "initial native distributed profile requires --world-size 2 and --rank 0 or 1",
    )
  }
  let session_id = required(args, "--session-id")
  guard session_id.length() >= 16 &&
    session_id.length() <= 128 &&
    session_id
    .iter()
    .all(c => {
      (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '-' ||
      c == '_'
    }) else {
    fail(
      "--session-id must be a fresh 16..128 character alphanumeric/hyphen/underscore identifier",
    )
  }
  let timeout_ms = match option(args, "--nccl-timeout-ms") {
    Some(value) => @string.parse_int(value)
    None => 30000
  }
  guard timeout_ms >= 1000 && timeout_ms <= 60000 else {
    fail(
      "--nccl-timeout-ms must be within 1000..60000; use an external process watchdog as well",
    )
  }
  let data_ready_timeout_seconds = match
    option(args, "--data-ready-timeout-seconds") {
    None => None
    Some(text) => {
      let seconds = @string.parse_int(text)
      guard seconds >= 60 && seconds <= 21600 else {
        fail(
          "--data-ready-timeout-seconds must be 60..21600; this does not change NCCL ticket TTL",
        )
      }
      Some(seconds)
    }
  }
  Some({
    rank,
    world_size,
    session_id,
    timeout_ms,
    data_ready_timeout_seconds,
    id_file: required(args, "--nccl-id-file"),
  })
}

///|
struct RendezvousFile {
  format : String
  session_id : String
  world_size : Int32
  created_unix_ms : Int64
  expires_unix_ms : Int64
  id : Array[Int32]
} derive(ToJson, FromJson)

///|
extern "C" fn unix_milliseconds() -> Int64 = "moonrobo_native_trainer_unix_ms"

///|
fn validate_rendezvous(
  value : RendezvousFile,
  settings : DistributedSettings,
  now : Int64,
) -> Bytes raise {
  guard value.format == "moonrobo.native-nccl-rendezvous.v1" &&
    value.session_id == settings.session_id &&
    value.world_size == settings.world_size &&
    value.id.length() == 128 &&
    value.id.all(v => v >= 0 && v <= 255) else {
    fail("NCCL rendezvous identity or 128-byte ID mismatch")
  }
  guard now > 0L &&
    value.created_unix_ms > 0L &&
    value.created_unix_ms <= now + 10000L &&
    value.expires_unix_ms > now &&
    value.expires_unix_ms - value.created_unix_ms ==
    settings.timeout_ms.to_int64() else {
    fail(
      "expired NCCL rendezvous or host clock disagreement; start both ranks with a fresh session and ID file",
    )
  }
  Bytes::makei(128, i => value.id[i].to_byte())
}

///|
/// Rank zero publishes a fresh ID only after local dataset/preflight work. Its
/// process must remain alive while the file is copied out of band to rank one.
/// A fresh session plus CreateNew consumption records rejects accidental reuse;
/// only NCCL's live handshake establishes peer readiness.
async fn connect_distributed(
  backend : @tensor.Backend,
  settings : DistributedSettings,
  device : Int32,
) -> @tensor.Collective {
  let local_deadline = @async.now() + settings.timeout_ms.to_int64()
  let id = if settings.rank == 0 {
    guard !@fs.exists(settings.id_file) else {
      fail(
        "NCCL ID file already exists; never reuse a previous rank-zero rendezvous",
      )
    }
    let id = backend.nccl_id()
    let created = unix_milliseconds()
    guard created > 0L && id.length() == 128 else {
      fail("could not initialize fresh NCCL rendezvous")
    }
    let value : RendezvousFile = {
      format: "moonrobo.native-nccl-rendezvous.v1",
      session_id: settings.session_id,
      world_size: settings.world_size,
      created_unix_ms: created,
      expires_unix_ms: created + settings.timeout_ms.to_int64(),
      id: Array::makei(id.length(), i => id[i].to_int()),
    }
    let staged = settings.id_file + "." + settings.session_id + ".partial"
    @fs.write_file(
      staged,
      @utf8.encode(Json(value).stringify() + "\n"),
      create_mode=CreateNew,
      sync=Full,
    )
    @fs.rename(staged, settings.id_file, replace=false)
    sync_path(dirname(settings.id_file))
    println(
      (
        {
          "stage": "nccl-rendezvous-published",
          "rank": settings.rank,
          "session_id": settings.session_id,
          "id_file": settings.id_file,
          "expires_unix_ms": Json(value.expires_unix_ms),
          "external_process_watchdog_required": true,
        } : Json).stringify(),
    )
    id
  } else {
    while !@fs.exists(settings.id_file) {
      guard @async.now() < local_deadline else {
        fail("timed out waiting for copied NCCL ID file")
      }
      @async.sleep(100)
    }
    let value : RendezvousFile = @json.from_json(
      bounded_json(settings.id_file, 4096L),
    )
    validate_rendezvous(value, settings, unix_milliseconds())
  }
  // Keep a durable consumption record even after a crash. Session IDs must be
  // unique; the old file must not be used to reconnect an exited creator.
  let consumed = settings.id_file +
    "." +
    settings.session_id +
    ".rank-\{settings.rank}.consumed"
  @fs.write_file(consumed, "consumed\n", create_mode=CreateNew, sync=Full)
  let group = backend.nccl_connect(
    id,
    rank=settings.rank,
    world_size=settings.world_size,
    cuda_device=device,
    timeout_ms=settings.timeout_ms,
  )
  println(
    (
      {
        "stage": "nccl-connected",
        "rank": settings.rank,
        "world_size": settings.world_size,
        "session_id": settings.session_id,
      } : Json).stringify(),
  )
  group
}

///|
fn close_collective(group : @tensor.Collective?) -> Unit {
  if group is Some(value) {
    value.close() catch {
      _ => ()
    }
  }
}

///|
fn text_hash(value : String) -> String {
  let hash = @crypto.SHA256::new()
  hash.update(@utf8.encode(value))
  @crypto.bytes_to_hex_string(hash.finalize())
}

///|
/// The launch schedule is collective-sensitive but is deliberately separate
/// from durable run identity: a single-rank resume may extend its iteration cap.
fn distributed_launch_identity(identity : Json, settings : Settings) -> Json {
  let options = settings.options
  {
    "run_identity": identity,
    "effective_training_options": {
      "iterations": Json(options.iterations),
      "warmup_steps": Json(options.warmup_steps),
      "world_only_iterations": Json(options.world_only_iterations),
      "update_to_data": Json(options.update_to_data),
      "learning_rate_decay_iterations": Json(
        options.learning_rate_decay_iterations,
      ),
      "action_noise": Json(options.action_noise),
    },
    "checkpoint_every": Json(settings.checkpoint_every),
    "distributed_startup": match settings.distributed {
      None => Json::null()
      Some(distributed) =>
        {
          "nccl_timeout_ms": Json(distributed.timeout_ms),
          "data_ready_timeout_seconds": Json(
            distributed.data_ready_timeout_seconds,
          ),
        }
    },
  }
}

///|
fn assert_collective_identity(
  group : @tensor.Collective?,
  identity : Json,
) -> Unit raise {
  if group is Some(value) {
    let hash = @utf8.encode(text_hash(identity.stringify()))
    let signature = Array::makei(hash.length(), i => hash[i].to_int().to_int64())
    let low = value.control(signature, op=Min)
    let high = value.control(signature, op=Max)
    guard low == high else {
      fail(
        "native ranks disagree on executable/configuration/library/asset identity or effective training schedule; deploy the same build and inputs and use matching iteration/checkpoint options",
      )
    }
  }
}

///|
async fn publish_distributed_checkpoint(
  training : @runner.TrainingRunner,
  output : String,
  root_output : String,
  identity : Json,
  generation : String,
) -> Json {
  if training.learner.collective is None {
    return Json::null()
  }
  let manifest = training.distributed_checkpoint_manifest(
    file_hash(output + "/current.json"),
    text_hash(identity.stringify()),
    generation,
  )
  let bytes = @utf8.encode(Json(manifest).stringify(indent=2) + "\n")
  let digest = text_hash(Json(manifest).stringify(indent=2) + "\n")
  let name = "distributed-generation-\{manifest.iteration}-" + digest + ".json"
  // Each rank retains an immutable global manifest. Relative rank paths belong
  // to their respective hosts; no shared filesystem is assumed. Rank zero's
  // root pointer is an additional convenience and cannot race rank one's writer.
  @fs.write_file(output + "/" + name, bytes, create_mode=CreateNew, sync=Full)
  sync_path(output)
  let pointer : Json = {
    "format": "moonrobo.native-distributed-checkpoint-pointer.v1",
    "manifest": name,
    "manifest_sha256": digest,
    "resume_supported": false,
  }
  let temporary = output + "/.distributed-\{@async.now()}.partial"
  @fs.write_file(
    temporary,
    @utf8.encode(pointer.stringify(indent=2) + "\n"),
    create_mode=CreateNew,
    sync=Full,
  )
  @fs.rename(temporary, output + "/distributed-current.json", replace=true)
  sync_path(output)
  if training.learner.collective is Some(group) && group.rank == 0 {
    let pointer : Json = {
      "format": "moonrobo.native-distributed-checkpoint-pointer.v1",
      "manifest": "rank-0/" + name,
      "manifest_sha256": digest,
      "resume_supported": false,
    }
    let temporary = root_output + "/.distributed-\{@async.now()}.partial"
    @fs.write_file(
      temporary,
      @utf8.encode(pointer.stringify(indent=2) + "\n"),
      create_mode=CreateNew,
      sync=Full,
    )
    @fs.rename(
      temporary,
      root_output + "/distributed-current.json",
      replace=true,
    )
    sync_path(root_output)
  }
  Json(manifest)
}
