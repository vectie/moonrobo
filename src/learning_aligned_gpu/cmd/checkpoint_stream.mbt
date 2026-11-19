///|
enum CheckpointFormat {
  LegacyV1
  StreamV2
} derive(Eq)

///|
/// Capacity is part of the saved training identity, never inferred from sizes.
/// Missing field is legacy Initial; an explicit null or misspelling is invalid.
fn checkpoint_capacity(
  identity : Json,
  streaming : Bool,
) -> @capacity.CapacityProfile raise {
  guard identity is { "config": Object(config), .. } else {
    fail("checkpoint identity must contain a configuration object")
  }
  let profile = match config.get("capacity_profile") {
    None => @capacity.Initial
    Some(String(name)) => @capacity.CapacityProfile::parse(name)
    _ => fail("checkpoint capacity_profile must be an explicit string")
  }
  guard streaming || profile == @capacity.Initial else {
    fail("paper-4096 checkpoints require stream-v2; legacy JSON is unsupported")
  }
  profile
}

///|
fn checkpoint_state_capacity(
  state : Json,
  streaming : Bool,
) -> @capacity.CapacityProfile raise {
  guard state is { "identity": identity, .. } else {
    fail("checkpoint is missing its training identity")
  }
  checkpoint_capacity(identity, streaming)
}

///|
fn validate_checkpoint_capacity_dimensions(
  state : Json,
  streaming : Bool,
) -> @capacity.CapacityProfile raise {
  let profile = checkpoint_state_capacity(state, streaming)
  guard state
    is {
      "runtime": {
        "num_envs": environments,
        "capacity": replay_steps,
        "config": { "wm_batch": world_batch, "policy_batch": policy_batch, .. },
        ..
      },
      ..
    } else {
    fail("checkpoint runtime capacity dimensions are missing")
  }
  ignore(
    profile.validate_dimensions(
      environments=@json.from_json(environments),
      world_batch=@json.from_json(world_batch),
      policy_batch=@json.from_json(policy_batch),
      replay_steps=@json.from_json(replay_steps),
    ),
  )
  profile
}

///|
fn CheckpointFormat::name(self : CheckpointFormat) -> String {
  match self {
    LegacyV1 => "v1"
    StreamV2 => "stream-v2"
  }
}

///|
fn checkpoint_format(args : Array[String]) -> CheckpointFormat raise {
  let mut value = LegacyV1
  let mut found = false
  for i, arg in args {
    if arg != "--checkpoint-format" {
      continue
    }
    guard !found && i + 1 < args.length() else {
      fail("missing or duplicate --checkpoint-format")
    }
    found = true
    value = match args[i + 1] {
      "v1" => LegacyV1
      "stream-v2" => StreamV2
      _ => fail("--checkpoint-format must be v1 or stream-v2")
    }
  }
  value
}

///|
struct StreamGeneration {
  format : String
  identity : Json
  learner : @gpu.CheckpointMetadata
  runtime : @runner.RuntimeSnapshotV2
  environment : StreamEnvironment
  shared_state_digest : @gpu.SharedStateDigest?
} derive(ToJson, FromJson)

///|
enum LoadedGeneration {
  Legacy(SavedGeneration)
  Stream(StreamGeneration)
}

///|
fn LoadedGeneration::learner(
  self : LoadedGeneration,
) -> @gpu.CheckpointMetadata {
  match self {
    Legacy(saved) => saved.learner
    Stream(saved) => saved.learner
  }
}

///|
fn LoadedGeneration::attestation(
  self : LoadedGeneration,
) -> @gpu.SharedStateDigest? {
  match self {
    Legacy(saved) => saved.shared_state_digest
    Stream(saved) => saved.shared_state_digest
  }
}

///|
async fn restore_generation(
  directory : String,
  saved : LoadedGeneration,
  training : @runner.TrainingRunner,
  environment : ExecutionEnvironment,
) -> Bool {
  match saved {
    Legacy(saved) => {
      let profile = checkpoint_capacity(saved.identity, false)
      ignore(
        profile.validate_dimensions(
          environments=saved.runtime.num_envs,
          world_batch=saved.runtime.config.wm_batch,
          policy_batch=saved.runtime.config.policy_batch,
          replay_steps=saved.runtime.capacity,
        ),
      )
    }
    Stream(saved) => ignore(stream_blobs(saved))
  }
  let learner = training.learner
  learner.restore_metadata(saved.learner())
  learner.load_optimizers(directory)
  if saved.attestation() is Some(expected) {
    guard Json(learner.attest_shared_state()) == Json(expected) else {
      fail(
        "restored native learner weights/Adam/normalizers differ from checkpoint attestation",
      )
    }
  }
  match saved {
    Legacy(saved) => {
      let exact = (environment.restore_fn)(saved.environment)
      training.restore(saved.runtime, exact)
      exact
    }
    Stream(saved) => {
      // Validate and stage runtime values before any physical state mutation.
      let prepared = training.prepare_snapshot_v2(directory, saved.runtime)
      let exact = environment.restore_stream(directory, saved.environment)
      training.commit_snapshot_v2(prepared, exact)
      exact
    }
  }
}

///|
fn stream_blobs(
  saved : StreamGeneration,
) -> Array[@stream.BlobDescriptor] raise {
  let r = saved.runtime
  let c = r.config
  let profile = checkpoint_capacity(saved.identity, true)
  ignore(
    profile.validate_dimensions(
      environments=r.num_envs,
      world_batch=c.wm_batch,
      policy_batch=c.policy_batch,
      replay_steps=r.capacity,
    ),
  )
  guard saved.environment.metadata is { "num_envs": environment_count, .. } &&
    environment_count == Json(r.num_envs) else {
    fail("stream runtime and physical environment counts differ")
  }
  guard saved.format == "moonrobo.native-tensor-training-generation.v2" &&
    r.format == "moonrobo-aligned-gpu-runtime-v2" &&
    c.hist > 0 &&
    c.hist <= 10 &&
    c.goal_frames > 0 &&
    c.goal_frames <= 10 &&
    c.horizon > 0 &&
    c.horizon <= 32 &&
    c.wm_window > 0 &&
    c.wm_window <= 8 &&
    Json(c) == Json(saved.learner.config) &&
    r.observation_mode == saved.learner.observation_mode else {
    fail("unsupported stream checkpoint runtime format or learner dimensions")
  }
  let mode : @aligned.ObservationMode = match r.observation_mode {
    "paper" => @aligned.Paper
    "smc" => @aligned.Smc
    "observable" => @aligned.Observable
    _ => fail("invalid stream observation mode")
  }
  r.replay.validate(r.capacity, r.num_envs)
  @aligned.checkpoint_blob(
    r.history_lengths,
    "history.lengths.i32le",
    "i32le",
    [r.num_envs],
  )
  @aligned.checkpoint_blob(r.history_values, "history.values.f64le", "f64le", [
    r.num_envs,
    c.hist,
    mode.dim(),
  ])
  validate_checkpoint_catalog_descriptor(
    r.catalog,
    r.catalog_count,
    r.catalog_digest,
  )
  let blobs = saved.runtime.blobs()
  blobs.append(saved.environment.blobs(profile~))
  blobs
}

///|
fn validate_checkpoint_catalog_descriptor(
  descriptor : @stream.BlobDescriptor,
  count : Int32,
  digest : String,
) -> Unit raise {
  @stream.validate_descriptor(descriptor)
  guard descriptor.file == "catalog.json" &&
    descriptor.dtype == "u8" &&
    descriptor.byte_length > 0L &&
    descriptor.byte_length <= 67108864L &&
    descriptor.shape == [descriptor.byte_length.to_int()] &&
    count > 0 &&
    count <= 200000 &&
    digest == descriptor.sha256 else {
    fail("invalid runtime catalog sidecar")
  }
}

///|
fn validate_checkpoint_catalog(
  value : Json,
  count : Int32,
  source_fps : Double,
) -> Json raise {
  guard value
    is {
      "format": "moonrobo.native-runtime-catalog.v2",
      "motion_names": Array(names),
      "motion_sha256": Array(hashes),
      "source_fps": fps,
      ..
    } &&
    count > 0 &&
    count <= 200000 &&
    names.length() == count &&
    hashes.length() == count &&
    names.all(name => name is String(_)) &&
    hashes.all(hash => hash is String(_)) &&
    fps == Json(source_fps) else {
    fail("checkpoint catalog count/source fps differs")
  }
  value
}

///|
fn safe_checkpoint_name(name : String) -> Bool {
  name.length() > 0 &&
  name.length() <= 255 &&
  name != "." &&
  name != ".." &&
  name
  .iter()
  .all(c => {
    (c >= 'a' && c <= 'z') ||
    (c >= 'A' && c <= 'Z') ||
    (c >= '0' && c <= '9') ||
    c == '.' ||
    c == '_' ||
    c == '-'
  })
}

///|
fn valid_checkpoint_sha(value : String) -> Bool {
  value.length() == 64 &&
  value.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
}

///|
/// Numeric replay/staging/profile caps remain enforced by runtime and settings.
/// Only the saved explicit Paper4096 identity selects the larger stream bounds.
fn validate_stream_members(
  blobs : Array[@stream.BlobDescriptor],
  state_bytes : Int64,
  profile~ : @capacity.CapacityProfile = @capacity.Initial,
) -> Unit raise {
  ignore(
    profile.validate_stream_totals(
      blobs.map(blob => blob.byte_length),
      state_bytes~,
    ),
  )
  let seen : Map[String, Bool] = {
    "world.pt": true,
    "policy.pt": true,
    "critic.pt": true,
    "state.json": true,
    "receipt.json": true,
  }
  for blob in blobs {
    @stream.validate_descriptor(blob)
    guard safe_checkpoint_name(blob.file) && !seen.contains(blob.file) else {
      fail("unsafe, duplicate or oversized stream checkpoint sidecar")
    }
    seen[blob.file] = true
    if blob.file == "catalog.json" {
      profile.validate_catalog_bytes(blob.byte_length)
    }
  }
}

///|
/// Exports/evaluations may need catalog names, but never numeric replay. Its
/// separate bounded decode is charged to host headroom rather than hidden in
/// the small checkpoint state metadata.
async fn checkpoint_catalog_json(directory : String, state : Json) -> Json {
  match state {
    {
      "format": "moonrobo.native-tensor-training-generation.v1",
      "runtime": {
        "motion_names": names,
        "motion_sha256": hashes,
        "source_fps": fps,
        ..
      },
      ..
    } => { "motion_names": names, "motion_sha256": hashes, "source_fps": fps }
    { "format": "moonrobo.native-tensor-training-generation.v2", .. } => {
      let saved : StreamGeneration = @json.from_json(
        normalized_checkpoint_attestation(state),
      )
      let descriptor = saved.runtime.catalog
      validate_checkpoint_catalog_descriptor(
        descriptor,
        saved.runtime.catalog_count,
        saved.runtime.catalog_digest,
      )
      @stream.verify_blob(directory, descriptor)
      guard host_available() >= descriptor.byte_length * 16L + 1073741824L else {
        fail("insufficient host headroom to decode checkpoint catalog")
      }
      let catalog = bounded_json(directory + "/catalog.json", 67108864L)
      validate_checkpoint_catalog(
        catalog,
        saved.runtime.catalog_count,
        saved.runtime.source_fps,
      )
    }
    _ => fail("unsupported checkpoint catalog format")
  }
}
