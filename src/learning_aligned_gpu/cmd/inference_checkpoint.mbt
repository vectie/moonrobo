///|
struct InferenceSource {
  format : String
  iteration : Int32
  identity : Json
  motion_names : Array[String]
  motion_sha256 : Array[String]
  source_fps : Double
  checkpoint_receipt_sha256 : String
  checkpoint_files : Map[String, String]
  shared_state_digest : Json
} derive(ToJson, FromJson)

///|
struct ActorArtifact {
  format : String
  spec : @inference.ActorSpec
  contract : Json
  source : InferenceSource
  archive_sha256 : String
  parameters : Array[@gpu.TensorStateDigest]
} derive(ToJson, FromJson)

///|
/// Distinct from the common training source: these fields describe the files
/// this invocation actually verified and passed to Actor::load_archive.
struct InferenceArchive {
  kind : String
  path : String
  sha256 : String
  metadata_path : String
  metadata_sha256 : String
}

///|
fn InferenceArchive::report(self : InferenceArchive) -> Json {
  {
    "loaded_archive_kind": Json(self.kind),
    "loaded_archive_path": Json(self.path),
    "loaded_archive_sha256": Json(self.sha256),
    "loaded_metadata_path": Json(self.metadata_path),
    "loaded_metadata_sha256": Json(self.metadata_sha256),
  }
}

///|
/// Hash the same bounded bytes that are decoded, without rereading the actor's
/// large tensor archive or making a second copy of its metadata payload.
async fn inference_hashed_json(path : String, limit : Int64) -> (Json, String) {
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  let size = file.size()
  guard size > 0L && size <= limit else {
    fail("inference JSON exceeds bounded input size: " + path)
  }
  let bytes = file.read_exactly_at(size.to_int(), position=0L)
  let hash = @crypto.SHA256::new()
  hash.update(bytes)
  let digest = @crypto.bytes_to_hex_string(hash.finalize())
  (@json.parse(@utf8.decode(bytes)), digest)
}

///|
fn optional_attestation(value : Json) -> Json raise {
  guard value is Object(fields) else {
    fail("attestation container must be object")
  }
  match fields.get("shared_state_digest") {
    None | Some(Null) => Json::null()
    Some(Object(_) as value) | Some(Array([Object(_) as value])) => {
      let digest : @gpu.SharedStateDigest = @json.from_json(value)
      guard digest.format == "moonrobo.shared-learner-state.v1" else {
        fail("unsupported attestation format")
      }
      Json(digest)
    }
    _ => fail("malformed shared-state attestation")
  }
}

///|
/// Do not deserialize runtime replay/histories: inference consumes only actor
/// metadata. Every archive hash is still checked against the immutable receipt.
async fn inference_checkpoint(
  pointer : String,
) -> (String, @inference.ActorSpec, InferenceSource, InferenceArchive) {
  let (directory, receipt, state) = verify_checkpoint_generation(pointer)
  guard state
    is {
      "identity": identity,
      "learner": metadata,
      "runtime": { "iteration": iteration, .. },
      ..
    } else {
    fail("invalid native training generation")
  }
  // v1 keeps the catalog in runtime JSON; opt-in stream-v2 stores a bounded
  // catalog sidecar. The shared verifier hashes all numeric sidecars without
  // materializing replay, histories, sampler state or physics arrays here.
  let catalog = checkpoint_catalog_json(directory, state)
  guard catalog
    is { "motion_names": names, "motion_sha256": hashes, "source_fps": fps, .. } else {
    fail("invalid checkpoint inference catalog")
  }
  let iteration : Int32 = @json.from_json(iteration)
  let source : InferenceSource = {
    format: "moonrobo.native-actor-source.v1",
    iteration,
    identity,
    motion_names: @json.from_json(names),
    motion_sha256: @json.from_json(hashes),
    source_fps: @json.from_json(fps),
    checkpoint_receipt_sha256: file_hash(directory + "/receipt.json"),
    checkpoint_files: receipt.files,
    shared_state_digest: optional_attestation(state),
  }
  guard iteration == receipt.iteration &&
    source.shared_state_digest ==
    (match receipt.shared_state_digest {
      Some(digest) => Json(digest)
      None => Json::null()
    }) &&
    !source.motion_names.is_empty() &&
    source.motion_names.length() <= 200000 &&
    source.motion_names.length() == source.motion_sha256.length() else {
    fail("checkpoint metadata/receipt differs")
  }
  let spec = @inference.ActorSpec::from_checkpoint(@json.from_json(metadata))
  let path = directory + "/policy.pt"
  // Both entries were checked against actual bytes above. Reuse those checked
  // digests instead of hashing policy.pt or the large state.json a second time.
  let loaded : InferenceArchive = {
    kind: "native_training_checkpoint",
    path,
    sha256: receipt.files["policy.pt"],
    metadata_path: directory + "/state.json",
    metadata_sha256: receipt.files["state.json"],
  }
  (path, spec, source, loaded)
}

///|
async fn inference_input(
  args : Array[String],
) -> (
  String,
  @inference.ActorSpec,
  InferenceSource,
  Array[@gpu.TensorStateDigest]?,
  InferenceArchive,
) {
  let checkpoint = option(args, "--checkpoint")
  let artifact = option(args, "--actor")
  match (checkpoint, artifact) {
    (Some(pointer), None) => {
      let (path, spec, source, loaded) = inference_checkpoint(pointer)
      (path, spec, source, None, loaded)
    }
    (None, Some(directory)) => {
      let size = bounded_physics_file(directory + "/actor.json", 67108864L)
      guard size * 16L + 1073741824L <= host_available() * 65L / 100L else {
        fail("insufficient memory to decode actor metadata safely")
      }
      let (metadata, metadata_sha256) = inference_hashed_json(
        directory + "/actor.json",
        67108864L,
      )
      let saved : ActorArtifact = @json.from_json(metadata)
      let profile = checkpoint_capacity(saved.source.identity, true)
      guard profile == @capacity.Initial ||
        saved.source.checkpoint_files.contains("catalog.json") else {
        fail("paper-4096 actor provenance requires a stream-v2 source catalog")
      }
      guard saved.format == "moonrobo.native-tensor-actor.v1" &&
        saved.source.format == "moonrobo.native-actor-source.v1" &&
        saved.contract == saved.spec.contract() else {
        fail("unsupported actor artifact/contract")
      }
      let path = directory + "/actor.pt"
      ignore(bounded_physics_file(path, 536870912L))
      guard file_hash(path) == saved.archive_sha256 else {
        fail("actor archive hash mismatch")
      }
      let loaded : InferenceArchive = {
        kind: "native_actor_export",
        path,
        sha256: saved.archive_sha256,
        metadata_path: directory + "/actor.json",
        metadata_sha256,
      }
      (path, saved.spec, saved.source, Some(saved.parameters), loaded)
    }
    _ =>
      fail(
        "provide exactly one --checkpoint RUN/current.json or --actor EXPORTED_DIRECTORY",
      )
  }
}

///|
/// Account for temporary archive decoding/moments and host initialization before
/// actor allocation. No training graph or replay is constructed in this path.
async fn inference_memory(
  backend : @tensor.Backend,
  device : Int32,
  archive : String,
  spec : @inference.ActorSpec,
  physics_reserve : Int64,
) -> Json {
  spec.validate()
  let bytes = bounded_physics_file(archive, 536870912L)
  let params = mlp_parameters(spec.goal_frames * 73, spec.hidden, 32, false) +
    mlp_parameters(spec.mode().dim() * spec.hist + 32, spec.hidden, 29, false)
  let host = host_available()
  let cuda = if device < 0 {
    None
  } else {
    guard device < backend.cuda_device_count() else {
      fail("inference CUDA device unavailable")
    }
    Some(backend.cuda_free_bytes(device))
  }
  let available = cuda.map(x => x.min(host)).unwrap_or(host)
  let peak = bytes * 6L + params * 24L + 1073741824L + physics_reserve
  guard peak <= available * 65L / 100L else {
    fail(
      "inference memory budget exceeded: need \{peak}; available \{available}",
    )
  }
  {
    "host_free_bytes": Json(host),
    "cuda_free_bytes": Json(cuda),
    "budget_bytes": Json(available * 65L / 100L),
    "estimated_peak_bytes": Json(peak),
    "actor_only": true,
    "reference_and_physics_reserve_bytes": Json(physics_reserve),
  }
}
