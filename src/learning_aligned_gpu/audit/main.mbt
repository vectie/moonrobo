///|
struct Receipt {
  format : String
  generation : String
  iteration : Int32
  files : Map[String, String]
  shared_state_digest : @gpu.SharedStateDigest?
}

///|
struct ReceiptFields {
  format : String
  generation : String
  iteration : Int32
  files : Map[String, String]
} derive(FromJson)

///|
/// Legacy generations omit the field or store null. Attested v1 generations
/// exist with both a direct digest object (derived optional struct field) and
/// [digest] (explicit Json(Option)). Accept exactly those documented encodings.
fn decode_attestation(document : Json) -> @gpu.SharedStateDigest? raise {
  guard document is Object(fields) else {
    fail("checkpoint attestation container must be an object")
  }
  let value = match fields.get("shared_state_digest") {
    None | Some(Null) => return None
    Some(Object(_) as value) => value
    Some(Array([Object(_) as value])) => value
    _ =>
      fail(
        "invalid checkpoint attestation encoding: expected object, [object], null or absent field",
      )
  }
  let digest : @gpu.SharedStateDigest = @json.from_json(value)
  guard digest.format == "moonrobo.shared-learner-state.v1" else {
    fail("unsupported checkpoint shared-state attestation schema")
  }
  Some(digest)
}

///|
fn decode_receipt(value : Json) -> Receipt raise {
  let fields : ReceiptFields = @json.from_json(value)
  {
    format: fields.format,
    generation: fields.generation,
    iteration: fields.iteration,
    files: fields.files,
    shared_state_digest: decode_attestation(value),
  }
}

///|
fn verify_attestation(
  receipt : @gpu.SharedStateDigest?,
  state : @gpu.SharedStateDigest?,
  actual : @gpu.SharedStateDigest,
) -> Bool? raise {
  match (receipt, state) {
    (None, None) => None
    (Some(receipt_digest), Some(state_digest)) => {
      guard Json(receipt_digest) == Json(actual) &&
        Json(state_digest) == Json(actual) else {
        fail("checkpoint readback differs from held-state attestation")
      }
      Some(true)
    }
    _ => fail("checkpoint state and receipt attestation presence differs")
  }
}

///|
struct GenerationAudit {
  directory : String
  checkpoint_format : String
  iteration : Int32
  identity : Json
  shared : @gpu.SharedStateDigest
  archive_bytes : Int64
  state_json_bytes : Int64
  streamed_sidecar_bytes : Int64
  streamed_sidecar_count : Int32
  planned_peak_host_bytes : Int64
  held_state_attestation_verified : Bool?
} derive(ToJson)

///|
fn option(args : Array[String], name : String) -> String? raise {
  for i, arg in args {
    if arg == name {
      guard i + 1 < args.length() else { fail("missing value: " + name) }
      return Some(args[i + 1])
    }
  }
  None
}

///|
fn required(args : Array[String], name : String) -> String raise {
  guard option(args, name) is Some(value) else {
    fail("required option: " + name)
  }
  value
}

///|
priv enum AuditMode {
  Generation(String)
  Pair(String, String)
} derive(Eq, Debug)

///|
fn mode_option(args : Array[String], name : String) -> String? raise {
  let mut value = None
  for i, arg in args {
    if arg == name {
      guard value is None else { fail("duplicate option: " + name) }
      guard i + 1 < args.length() &&
        !args[i + 1].is_empty() &&
        !args[i + 1].has_prefix("--") else {
        fail("missing value: " + name)
      }
      value = Some(args[i + 1])
    }
  }
  value
}

///|
fn audit_mode(args : Array[String]) -> AuditMode raise {
  let generation = mode_option(args, "--generation")
  let left = mode_option(args, "--left")
  let right = mode_option(args, "--right")
  match (generation, left, right) {
    (Some(path), None, None) => Generation(path)
    (None, Some(left), Some(right)) => Pair(left, right)
    (Some(_), _, _) =>
      fail("--generation is mutually exclusive with --left and --right")
    _ => fail("provide --generation PATH or both --left PATH and --right PATH")
  }
}

///|
/// Called only after audit_generation has verified the complete generation.
/// A missing legacy attestation remains absent; it is not promoted to true.
fn verification_report(generation : GenerationAudit) -> Json {
  {
    "format": "moonrobo.native-checkpoint-verification.v1",
    "device": "cpu",
    "read_only": true,
    "training_executed": false,
    "comparison_performed": false,
    "rank_local_state_compared": false,
    "verification_passed": true,
    "generation": Json(generation),
  }
}

///|
async fn bounded_json(path : String, maximum : Int64) -> Json {
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  let size = file.size()
  guard size > 0L && size <= maximum else {
    fail("JSON exceeds audit bound: " + path)
  }
  @json.parse(@utf8.decode(file.read_exactly_at(size.to_int(), position=0L)))
}

///|
async fn file_hash(
  path : String,
  maximum~ : Int64 = 536870912L,
) -> (String, Int64) {
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  let size = file.size()
  guard size > 0L && size <= maximum else {
    fail("checkpoint member exceeds audit size bound: " + path)
  }
  let hash = @crypto.SHA256::new()
  for offset = 0L; offset < size; {
    let count = (size - offset).min(65536L).to_int()
    hash.update(file.read_exactly_at(count, position=offset))
    continue offset + count.to_int64()
  }
  (@crypto.bytes_to_hex_string(hash.finalize()), size)
}

///|
fn stream_inventory(
  blobs : Array[@stream.BlobDescriptor],
  files : Map[String, String],
  state_json_bytes : Int64,
  profile~ : @capacity.CapacityProfile = @capacity.Initial,
) -> Int64 raise {
  let total = profile.validate_stream_totals(
    blobs.map(blob => blob.byte_length),
    state_bytes=state_json_bytes,
  )
  let names : Map[String, Bool] = {
    "world.pt": true,
    "policy.pt": true,
    "critic.pt": true,
    "state.json": true,
  }
  for blob in blobs {
    @stream.validate_descriptor(blob)
    guard blob.file != "receipt.json" &&
      !names.contains(blob.file) &&
      blob.file
      .iter()
      .all(c => {
        (c >= 'a' && c <= 'z') ||
        (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9') ||
        c == '.' ||
        c == '_' ||
        c == '-'
      }) &&
      files.get(blob.file) == Some(blob.sha256) else {
      fail("stream-v2 duplicate/reserved sidecar or receipt mismatch")
    }
    names[blob.file] = true
    if blob.file == "catalog.json" {
      profile.validate_catalog_bytes(blob.byte_length)
    }
  }
  guard files.length() == names.length() &&
    names.keys().all(name => files.contains(name)) else {
    fail("stream-v2 receipt file inventory differs from typed sidecars")
  }
  total - state_json_bytes
}

///|
fn stream_blobs(state : Json) -> Array[@stream.BlobDescriptor] raise {
  let profile = validate_capacity_state(state, true)
  guard state
    is {
      "runtime": runtime,
      "environment": environment,
      "learner": learner,
      ..
    } else {
    fail("missing stream-v2 runtime/environment metadata")
  }
  let runtime : @runner.RuntimeSnapshotV2 = @json.from_json(runtime)
  let metadata : @gpu.CheckpointMetadata = @json.from_json(learner)
  let c = runtime.config
  guard runtime.format == "moonrobo-aligned-gpu-runtime-v2" &&
    runtime.replay.format == "moonrobo.replay-stream.v2" &&
    runtime.catalog.file == "catalog.json" &&
    runtime.catalog.dtype == "u8" &&
    runtime.catalog.byte_length > 0L &&
    runtime.catalog.byte_length <= 67108864L &&
    runtime.catalog_count > 0 &&
    runtime.catalog_count <= 200000 &&
    runtime.catalog_digest == runtime.catalog.sha256 &&
    Json(c) == Json(metadata.config) &&
    runtime.observation_mode == metadata.observation_mode &&
    c.hist > 0 &&
    c.hist <= 10 &&
    c.goal_frames > 0 &&
    c.goal_frames <= 10 &&
    c.horizon > 0 &&
    c.horizon <= 32 &&
    c.wm_window > 0 &&
    c.wm_window <= 8 else {
    fail("invalid stream-v2 catalog metadata")
  }
  let mode : @aligned.ObservationMode = match runtime.observation_mode {
    "paper" => @aligned.Paper
    "smc" => @aligned.Smc
    "observable" => @aligned.Observable
    _ => fail("invalid stream observation mode")
  }
  runtime.replay.validate(runtime.capacity, runtime.num_envs)
  @aligned.checkpoint_blob(
    runtime.history_lengths,
    "history.lengths.i32le",
    "i32le",
    [runtime.num_envs],
  )
  @aligned.checkpoint_blob(
    runtime.history_values,
    "history.values.f64le",
    "f64le",
    [runtime.num_envs, c.hist, mode.dim()],
  )
  @aligned.checkpoint_blob(runtime.catalog, "catalog.json", "u8", [
    runtime.catalog.byte_length.to_int(),
  ])
  let blobs = runtime.blobs()
  match environment {
    { "backend": "mujoco-cpu-native", "metadata": metadata, .. } => {
      let saved : @tracking.EnvironmentSnapshotV2 = @json.from_json(metadata)
      guard saved.format == "moonrobo.aligned.mujoco-stream.v2" &&
        saved.num_envs == runtime.num_envs &&
        saved.num_envs <= profile.limits().max_environments &&
        saved.integration_width > 0 &&
        saved.num_envs.to_int64() * saved.integration_width.to_int64() <=
        16777216L else {
        fail("unsupported stream-v2 MuJoCo/sampler schema")
      }
      validate_sampler(saved.sampler)
      @aligned.checkpoint_blob(
        saved.physics,
        "environment.physics.f64le",
        "f64le",
        [saved.num_envs, saved.integration_width],
      )
      @aligned.checkpoint_blob(
        saved.values,
        "environment.values.f64le",
        "f64le",
        [saved.num_envs, 64],
      )
      @aligned.checkpoint_blob(
        saved.indices,
        "environment.indices.i32le",
        "i32le",
        [saved.num_envs, 3],
      )
      @aligned.checkpoint_blob(
        saved.initialized,
        "environment.initialized.u8",
        "u8",
        [saved.num_envs],
      )
      blobs.append(saved.blobs())
    }
    { "backend": "isaac-newton-warp-apic-native", "metadata": metadata, .. } => {
      let saved : @gpu_protocol.ProtocolSnapshotV2 = @json.from_json(metadata)
      guard saved.format == "moonrobo.aligned.isaac-warm-stream.v2" &&
        saved.num_envs == runtime.num_envs &&
        saved.num_envs <= profile.limits().max_environments &&
        !saved.exact_resume &&
        saved.replay_refill_required else {
        fail("unsupported stream-v2 APIC warm checkpoint schema")
      }
      validate_sampler(saved.sampler)
      @aligned.checkpoint_blob(saved.xi, "environment.xi.f64le", "f64le", [
        saved.num_envs,
        33,
      ])
      blobs.append(saved.blobs())
    }
    _ => fail("unsupported stream-v2 physical backend metadata")
  }
  blobs
}

///|
async fn audit_generation(
  backend : @tensor.Backend,
  directory : String,
  maximum_host : Int64,
) -> GenerationAudit {
  let receipt = decode_receipt(
    bounded_json(directory + "/receipt.json", 65536L),
  )
  let stream = receipt.format == "moonrobo.native-tensor-checkpoint-pointer.v2"
  guard (
      receipt.format == "moonrobo.native-tensor-checkpoint-pointer.v1" || stream
    ) &&
    receipt.generation.has_prefix("generation-") &&
    !receipt.generation.contains("/") &&
    !receipt.generation.contains("..") &&
    !receipt.generation.has_suffix(".partial") &&
    receipt.iteration >= 0 &&
    (if stream {
      receipt.files.length() > 4 && receipt.files.length() <= 68
    } else {
      receipt.files.length() == 4
    }) else {
    fail("invalid immutable generation receipt")
  }
  let mut archive_bytes = 0L
  let mut state_json_bytes = 0L
  for name in ["world.pt", "policy.pt", "critic.pt", "state.json"] {
    let (actual, size) = file_hash(
      directory + "/" + name,
      maximum=if stream && name == "state.json" { 4194304L } else { 536870912L },
    )
    guard receipt.files.get(name) is Some(expected) && actual == expected else {
      fail("checkpoint SHA256 differs from receipt: " + name)
    }
    if name == "state.json" {
      state_json_bytes = size
    } else {
      archive_bytes += size
    }
  }
  // Allow boxed JSON, CPU model initialization, archive decode, parameters and
  // Adam slots simultaneously. Load only one generation; no simulator/replay.
  let planned_peak_host_bytes = state_json_bytes * 16L +
    archive_bytes * 6L +
    1073741824L
  let available = host_available()
  guard planned_peak_host_bytes <= maximum_host &&
    planned_peak_host_bytes <= available * 65L / 100L else {
    fail(
      "audit host budget exceeded: need \{planned_peak_host_bytes} bytes, explicit cap \{maximum_host}, available \{available}",
    )
  }
  let state = bounded_json(
    directory + "/state.json",
    if stream {
      4194304L
    } else {
      536870912L
    },
  )
  guard state
    is {
      "format": String(format),
      "learner": learner,
      "identity": identity,
      "runtime": { "iteration": iteration, .. },
      ..
    } else {
    fail("invalid native generation state")
  }
  guard format ==
    (if stream {
      "moonrobo.native-tensor-training-generation.v2"
    } else {
      "moonrobo.native-tensor-training-generation.v1"
    }) else {
    fail("checkpoint receipt and state schema versions differ")
  }
  let iteration : Int32 = @json.from_json(iteration)
  guard iteration == receipt.iteration else {
    fail("checkpoint receipt/runtime iteration differs")
  }
  let blobs = if stream { stream_blobs(state) } else { [] }
  let profile = validate_capacity_state(state, stream)
  let streamed_sidecar_bytes = if stream {
    stream_inventory(blobs, receipt.files, state_json_bytes, profile~)
  } else {
    0L
  }
  // This validates every payload's exact length and SHA in bounded chunks.
  // Rank-local replay/physics values are not reconstructed or compared here.
  for blob in blobs {
    @stream.verify_blob(directory, blob)
  }
  let metadata : @gpu.CheckpointMetadata = @json.from_json(learner)
  let shared = @gpu.checkpoint_state_digest(backend, directory, metadata)
  let held_state_attestation_verified = verify_attestation(
    receipt.shared_state_digest,
    decode_attestation(state),
    shared,
  )
  {
    directory,
    checkpoint_format: receipt.format,
    iteration,
    identity,
    shared,
    archive_bytes,
    state_json_bytes,
    streamed_sidecar_bytes,
    streamed_sidecar_count: blobs.length(),
    planned_peak_host_bytes,
    held_state_attestation_verified,
  }
}

///|
async fn run_audit() -> Unit {
  let args = @env.args()
  // Reject mixed/incomplete modes before opening a native backend or files.
  let mode = audit_mode(args)
  let maximum_mib = @string.parse_int64(
    option(args, "--max-host-mib").unwrap_or("8192"),
  )
  guard maximum_mib >= 1024L && maximum_mib <= 65536L else {
    fail("--max-host-mib must be in [1024,65536]")
  }
  let backend = @tensor.Backend::open(required(args, "--tensor-library"))
  let (left_path, right_path) = match mode {
    Generation(directory) => {
      let generation = audit_generation(
        backend,
        directory,
        maximum_mib * 1048576L,
      )
      println(verification_report(generation).stringify(indent=2))
      return
    }
    Pair(left, right) => (left, right)
  }
  // The first generation's tensor/optimizer handles die when audit_generation
  // returns. Only small hashes/metadata remain while reading the second.
  let left = audit_generation(backend, left_path, maximum_mib * 1048576L)
  let right = audit_generation(backend, right_path, maximum_mib * 1048576L)
  let identity_equal = left.identity == right.identity
  let iteration_equal = left.iteration == right.iteration
  let shared_state_equal = left.shared.sha256 == right.shared.sha256
  let report : Json = {
    "format": "moonrobo.native-checkpoint-semantic-comparison.v1",
    "device": "cpu",
    "read_only": true,
    "training_executed": false,
    "rank_local_state_compared": false,
    "archive_hash_equality_required": false,
    "identity_equal": identity_equal,
    "iteration_equal": iteration_equal,
    "shared_state_equal": shared_state_equal,
    "left": Json(left),
    "right": Json(right),
  }
  println(report.stringify(indent=2))
  guard identity_equal && iteration_equal && shared_state_equal else {
    fail("native checkpoint shared state differs")
  }
}

///|
async fn main {
  run_audit() catch {
    @tensor.TensorError::Native(message) =>
      fail("native checkpoint audit failed: " + message)
    error => raise error
  }
}
