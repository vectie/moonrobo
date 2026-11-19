///|
struct SavedGeneration {
  format : String
  identity : Json
  learner : @gpu.CheckpointMetadata
  runtime : @runner.RuntimeSnapshot
  environment : Json
  shared_state_digest : @gpu.SharedStateDigest?
} derive(ToJson, FromJson)

///|
struct GenerationReceipt {
  format : String
  generation : String
  iteration : Int32
  files : Map[String, String]
  shared_state_digest : @gpu.SharedStateDigest?
} derive(ToJson, FromJson)

///|
fn normalized_checkpoint_attestation(value : Json) -> Json raise {
  guard value is Object(fields) else {
    fail("checkpoint document must be an object")
  }
  let normalized = fields.copy()
  // Derived optional record fields encode None by absence. A present null
  // would instead be decoded as a SharedStateDigest and fail.
  match optional_attestation(value) {
    Null => normalized.remove("shared_state_digest")
    digest => normalized["shared_state_digest"] = digest
  }
  Json(normalized)
}

///|
fn dirname(path : String) -> String {
  let parts = path.split("/").to_array()
  if parts.length() <= 1 {
    return "."
  }
  let prefix = parts[0:parts.length() - 1].map(x => x.to_owned()).join("/")
  if prefix == "" {
    "/"
  } else {
    prefix
  }
}

///|
async fn sync_path(path : String) -> Unit {
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  file.sync()
}

///|
async fn publish_checkpoint(
  output : String,
  training : @runner.TrainingRunner,
  environment : ExecutionEnvironment,
  identity : Json,
  plan : MemoryPlan,
  format~ : CheckpointFormat = LegacyV1,
) -> GenerationReceipt {
  let profile = checkpoint_capacity(identity, format == StreamV2)
  ignore(
    profile.validate_dimensions(
      environments=training.num_envs,
      world_batch=training.learner.config.wm_batch,
      policy_batch=training.learner.config.policy_batch,
      replay_steps=training.capacity,
    ),
  )
  let required_host = checkpoint_publication_headroom(profile, plan.components)
  guard host_available() > required_host else {
    fail(
      "insufficient host headroom for atomic checkpoint; previous generation retained",
    )
  }
  if checkpoint_output_headroom(profile, plan.components) is Some(required_disk) {
    guard output_free_bytes(output) >= required_disk else {
      fail(
        "insufficient output disk headroom for paper-4096 checkpoint; previous generation retained",
      )
    }
  }
  // All ranks hash the actual held weights, Adam state and normalizers before
  // publication. This is bounded host chunking, not a full model/replay clone.
  let shared_state_digest = Some(training.learner.attest_shared_state())
  let generation = "generation-\{training.iteration}-\{@async.now()}"
  let staging = output + "/" + generation + ".partial"
  @fs.mkdir(staging)
  // Every generation is fresh. Never overwrite one optimizer while another
  // still belongs to an older iteration.
  training.learner.save_optimizers(staging)
  let (state, blobs) = match format {
    LegacyV1 => {
      let saved : SavedGeneration = {
        format: "moonrobo.native-tensor-training-generation.v1",
        identity,
        learner: training.learner.checkpoint_metadata(),
        runtime: training.snapshot(),
        environment: (environment.snapshot_fn)(),
        shared_state_digest,
      }
      (Json(saved), [])
    }
    StreamV2 => {
      // These APIs write live arrays in bounded chunks; never call the v1
      // snapshot methods, whose replay/sampler copies defeat streaming.
      let saved : StreamGeneration = {
        format: "moonrobo.native-tensor-training-generation.v2",
        identity,
        learner: training.learner.checkpoint_metadata(),
        runtime: training.write_snapshot_v2(staging),
        environment: environment.write_stream(staging),
        shared_state_digest,
      }
      (Json(saved), stream_blobs(saved))
    }
  }
  seal_checkpoint_generation(
    output,
    generation,
    training.iteration,
    state,
    blobs,
    shared_state_digest,
    format,
  )
}

///|
/// Seals a fresh staged generation only after all payloads have been checked.
/// The caller's memory preflight and paused training snapshot precede this.
async fn seal_checkpoint_generation(
  output : String,
  generation : String,
  iteration : Int32,
  state : Json,
  blobs : Array[@stream.BlobDescriptor],
  shared_state_digest : @gpu.SharedStateDigest?,
  format : CheckpointFormat,
) -> GenerationReceipt {
  let profile = checkpoint_state_capacity(state, format == StreamV2)
  guard safe_checkpoint_name(generation) &&
    generation.has_prefix("generation-") &&
    !generation.contains("..") &&
    !generation.has_suffix(".partial") &&
    iteration >= 0 else {
    fail("invalid generation to publish")
  }
  let staging = output + "/" + generation + ".partial"
  let destination = output + "/" + generation
  let state_bytes = @utf8.encode(state.stringify() + "\n")
  let state_limit = if format == StreamV2 { 4194304 } else { 536870912 }
  guard state_bytes.length() <= state_limit else {
    fail("native checkpoint JSON exceeds format-specific initial profile limit")
  }
  if format == StreamV2 {
    validate_stream_members(blobs, state_bytes.length().to_int64(), profile~)
  } else {
    guard blobs.is_empty() else {
      fail("legacy checkpoint cannot contain stream sidecars")
    }
  }
  @fs.write_file(
    staging + "/state.json",
    state_bytes,
    create_mode=CreateNew,
    sync=Full,
  )
  let hashes : Map[String, String] = Map([])
  for name in ["world.pt", "policy.pt", "critic.pt", "state.json"] {
    ignore(bounded_physics_file(staging + "/" + name, 536870912L))
    sync_path(staging + "/" + name)
    hashes[name] = file_hash(staging + "/" + name)
  }
  for blob in blobs {
    @stream.verify_blob(staging, blob)
    hashes[blob.file] = blob.sha256
  }
  let receipt : GenerationReceipt = {
    format: if format == StreamV2 {
      "moonrobo.native-tensor-checkpoint-pointer.v2"
    } else {
      "moonrobo.native-tensor-checkpoint-pointer.v1"
    },
    generation,
    iteration,
    files: hashes,
    shared_state_digest,
  }
  let bytes = @utf8.encode(Json(receipt).stringify(indent=2) + "\n")
  @fs.write_file(
    staging + "/receipt.json",
    bytes,
    create_mode=CreateNew,
    sync=Full,
  )
  sync_path(staging)
  @fs.rename(staging, destination, replace=false)
  sync_path(output)
  let pointer = output + "/.current-\{@async.now()}.partial"
  @fs.write_file(pointer, bytes, create_mode=CreateNew, sync=Full)
  @fs.rename(pointer, output + "/current.json", replace=true)
  sync_path(output)
  receipt
}

///|
async fn read_checkpoint(
  pointer : String,
  identity : Json,
) -> (String, LoadedGeneration) {
  let (directory, _, state) = verify_checkpoint_generation(pointer)
  let saved = match state {
    {
      "format": "moonrobo.native-tensor-training-generation.v1",
      "identity": actual,
      ..
    } => {
      guard actual == identity else {
        fail("native checkpoint identity/configuration mismatch")
      }
      Legacy(@json.from_json(normalized_checkpoint_attestation(state)))
    }
    {
      "format": "moonrobo.native-tensor-training-generation.v2",
      "identity": actual,
      ..
    } => {
      guard actual == identity else {
        fail("native checkpoint identity/configuration mismatch")
      }
      Stream(@json.from_json(normalized_checkpoint_attestation(state)))
    }
    _ => fail("unsupported checkpoint generation")
  }
  (directory, saved)
}

///|
/// Shared by training and inference. All members are checked before a fresh
/// learner is mutated; v2 only parses small metadata and streams sidecar hashes.
async fn verify_checkpoint_generation(
  pointer : String,
) -> (String, GenerationReceipt, Json) {
  let receipt : GenerationReceipt = @json.from_json(
    normalized_checkpoint_attestation(bounded_json(pointer, 65536L)),
  )
  let streaming = receipt.format ==
    "moonrobo.native-tensor-checkpoint-pointer.v2"
  guard (
      streaming ||
      receipt.format == "moonrobo.native-tensor-checkpoint-pointer.v1"
    ) &&
    receipt.generation.has_prefix("generation-") &&
    safe_checkpoint_name(receipt.generation) &&
    !receipt.generation.contains("..") &&
    !receipt.generation.has_suffix(".partial") &&
    (
      (streaming && receipt.files.length() > 4 && receipt.files.length() <= 68) ||
      (!streaming && receipt.files.length() == 4)
    ) &&
    receipt.iteration >= 0 else {
    fail("invalid native checkpoint generation pointer")
  }
  let directory = dirname(pointer) + "/" + receipt.generation
  let stored_receipt : GenerationReceipt = @json.from_json(
    normalized_checkpoint_attestation(
      bounded_json(directory + "/receipt.json", 65536L),
    ),
  )
  guard Json(stored_receipt) == Json(receipt) else {
    fail("checkpoint pointer and generation receipt differ")
  }
  // Validate all archive bytes before mutating a newly constructed learner.
  for name in ["world.pt", "policy.pt", "critic.pt", "state.json"] {
    let file = @fs.open(directory + "/" + name, mode=ReadOnly)
    let size = file.size()
    file.close()
    guard size > 0L && size <= 536870912L else {
      fail("checkpoint member exceeds 512 MiB initial profile bound: " + name)
    }
    guard receipt.files.get(name) is Some(expected) &&
      valid_checkpoint_sha(expected) &&
      file_hash(directory + "/" + name) == expected else {
      fail("native checkpoint hash mismatch: " + name)
    }
  }
  let state = if streaming {
    let size = bounded_physics_file(directory + "/state.json", 4194304L)
    guard host_available() >= size * 16L + 1073741824L else {
      fail("insufficient host headroom for stream checkpoint metadata")
    }
    bounded_json(directory + "/state.json", 4194304L)
  } else {
    bounded_checkpoint_json(directory + "/state.json")
  }
  guard state
    is {
      "format": String(actual_format),
      "runtime": { "iteration": iteration, .. },
      ..
    } &&
    actual_format ==
    (if streaming {
      "moonrobo.native-tensor-training-generation.v2"
    } else {
      "moonrobo.native-tensor-training-generation.v1"
    }) &&
    iteration == Json(receipt.iteration) &&
    optional_attestation(state) ==
    receipt.shared_state_digest.map(x => Json(x)).unwrap_or(Json::null()) else {
    fail(
      "native checkpoint state/receipt format, iteration or attestation mismatch",
    )
  }
  if streaming {
    let saved : StreamGeneration = @json.from_json(
      normalized_checkpoint_attestation(state),
    )
    let blobs = stream_blobs(saved)
    let state_file = @fs.open(directory + "/state.json", mode=ReadOnly)
    let state_size = state_file.size()
    state_file.close()
    validate_stream_members(
      blobs,
      state_size,
      profile=checkpoint_capacity(saved.identity, true),
    )
    guard receipt.files.length() == 4 + blobs.length() else {
      fail("stream checkpoint receipt member set differs")
    }
    guard saved.runtime.catalog.file == "catalog.json" &&
      saved.runtime.catalog.dtype == "u8" &&
      saved.runtime.catalog.byte_length > 0L &&
      saved.runtime.catalog.byte_length <= 67108864L &&
      saved.runtime.catalog_count > 0 &&
      saved.runtime.catalog_count <= 200000 &&
      saved.runtime.catalog_digest == saved.runtime.catalog.sha256 else {
      fail("invalid stream checkpoint catalog descriptor")
    }
    for blob in blobs {
      guard receipt.files.get(blob.file) == Some(blob.sha256) else {
        fail("sidecar descriptor differs from receipt SHA: " + blob.file)
      }
      @stream.verify_blob(directory, blob)
    }
  }
  ignore(validate_checkpoint_capacity_dimensions(state, streaming))
  (directory, receipt, state)
}

///|
/// Initial keeps its conservative legacy envelope. A Paper4096 publication must
/// receive a separately admitted stream phase budget; never reuse or silently
/// reduce the legacy JSON estimate to enable a larger save.
fn checkpoint_publication_headroom(
  profile : @capacity.CapacityProfile,
  components : Map[String, Int64],
) -> Int64 raise {
  match profile {
    Initial => {
      guard components.get("host_replay_and_json_checkpoint_envelope")
        is Some(bytes) &&
        bytes >= 0L &&
        bytes <= 9223372035781033983L else {
        fail("missing or invalid legacy checkpoint publication envelope")
      }
      bytes + 1073741824L
    }
    Paper4096 => {
      guard components.get("host_checkpoint_stream_publication_headroom")
        is Some(bytes) &&
        bytes >= 1073741824L else {
        fail(
          "paper-4096 publication requires an admitted stream phase host headroom",
        )
      }
      bytes
    }
  }
}

///|
async fn bounded_checkpoint_json(path : String) -> Json {
  let file = @fs.open(path, mode=ReadOnly)
  let size = file.size()
  file.close()
  guard size > 0L && size <= 536870912L else {
    fail("checkpoint JSON exceeds native initial profile bound")
  }
  // Parsing temporarily holds UTF8, UTF16, Json nodes and decoded replay. The
  // factor is a conservative host envelope, not the compressed archive size.
  guard host_available() >= size * 16L + 1073741824L else {
    fail("insufficient host headroom to parse checkpoint JSON safely")
  }
  bounded_json(path, 536870912L)
}

///|
fn checkpoint_output_headroom(
  profile : @capacity.CapacityProfile,
  components : Map[String, Int64],
) -> Int64? raise {
  match profile {
    Initial => None
    Paper4096 => {
      guard components.get("minimum_output_free_bytes") is Some(bytes) &&
        bytes > 0L else {
        fail(
          "paper-4096 publication requires an admitted positive output disk budget",
        )
      }
      Some(bytes)
    }
  }
}
