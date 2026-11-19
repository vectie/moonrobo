///|
priv struct ReplayAttachment {
  format : String
  experiment_id : String
  experiment_summary : @data.DataRef
  replay : @data.DataRef
  assets : Array[@data.DataRef]
} derive(ToJson, FromJson)

///|
/// A verified, bounded asset payload. No caller-supplied filesystem path is
/// exposed by the replay HTTP route.
pub(all) struct ReplayAsset {
  bytes : Bytes
  content_type : String
  checksum : String
} derive(Debug)

///|
fn replay_source_id(id : String) -> String {
  "learning-replay-" + id
}

///|
fn replay_digest_is_valid(value : String) -> Bool {
  value.length() == 64 &&
  value.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
}

///|
fn replay_blob_bytes(
  root : String,
  data_ref : @data.DataRef,
  limit : Int32,
) -> Bytes raise {
  let digest = data_ref.checksum
    .strip_prefix("sha256:")
    .unwrap_or_else(() => fail("replay ref has no SHA-256 checksum"))
    .to_owned()
  guard replay_digest_is_valid(digest) &&
    data_ref.uri ==
    "moondata://blobs/sha256/" + digest[:2].to_owned() + "/" + digest &&
    data_ref.byte_count > 0L &&
    data_ref.byte_count <= limit.to_int64() else {
    fail("unsafe or oversized replay blob ref")
  }
  let path = root + "/blobs/sha256/" + digest[:2].to_owned() + "/" + digest
  guard need(@blob.local_file_size(path)) == data_ref.byte_count else {
    fail("replay evidence byte count mismatch")
  }
  let bytes = need(
    @blob.read_local_file_range(path, 0L, data_ref.byte_count.to_int()),
  )
  guard @data.bytes_checksum(bytes) == data_ref.checksum else {
    fail("replay evidence checksum mismatch")
  }
  bytes
}

///|
fn replay_parent_summary(root : String, id : String) -> @data.DataRef raise {
  ignore(read_experiment(root, id))
  let source = need(@store.read_source(root, source_id(id)))
  let summaries = source.source_refs.filter(ref_ => {
    ref_.kind == "learning-summary"
  })
  guard summaries.length() == 1 else {
    fail("ambiguous experiment summary binding")
  }
  summaries[0]
}

///|
fn replay_attachment(root : String, id : String) -> ReplayAttachment raise {
  guard valid_id(id) else { fail("invalid experiment id") }
  let summary = replay_parent_summary(root, id)
  guard @fsx.path_exists(@store.source_path(root, replay_source_id(id))) else {
    fail(
      "learning-replay-unavailable: no sealed full-body 3D recording is registered for this experiment",
    )
  }
  let source = need(@store.read_source(root, replay_source_id(id)))
  guard source.source_id == replay_source_id(id) &&
    source.kind == "learning-replay" else {
    fail("invalid replay source binding")
  }
  let attachments = source.source_refs.filter(ref_ => {
    ref_.kind == "learning-replay-attachment"
  })
  guard attachments.length() == 1 else { fail("ambiguous replay attachment") }
  let attachment : ReplayAttachment = @json.from_json(
    @json.parse(
      @utf8.decode(replay_blob_bytes(root, attachments[0], 1024 * 1024)),
    ),
  )
  guard attachment.format == "moonrobo.learning-replay-attachment.v1" &&
    attachment.experiment_id == id &&
    attachment.experiment_summary == summary &&
    attachment.replay.kind == "learning-pose-replay" &&
    attachment.assets.length() <= 2048 else {
    fail("replay attachment does not match the registered experiment")
  }
  for ref_ in [attachment.experiment_summary, attachment.replay] {
    guard source.source_refs.contains(ref_) else {
      fail("replay attachment ref is not registered")
    }
  }
  for asset in attachment.assets {
    guard asset.kind == "learning-replay-asset" &&
      source.source_refs.contains(asset) else {
      fail("replay asset ref is not registered")
    }
  }
  attachment
}

///|
fn replay_validated_json(bytes : Bytes, id : String) -> Json raise {
  let value = @json.parse(@utf8.decode(bytes))
  ignore(@learning_replay.validate_json(value))
  if value is Object(fields) && fields.get("experiment_id") is Some(artifact_id) {
    guard artifact_id == Json(id) else {
      fail("replay artifact experiment identity mismatch")
    }
  }
  value
}

///|
fn replay_payload_matches(
  experiment : LearningExperiment,
  kind : String,
  digest : String,
) -> Bool {
  replay_digest_is_valid(digest) &&
  experiment.payloads.any(payload => {
    payload.data_ref.kind == kind &&
    payload.data_ref.checksum == "sha256:" + digest
  })
}

///|
fn replay_provenance(
  value : Json,
  experiment : LearningExperiment,
) -> Unit raise {
  guard value is { "source": source, "clips": Array(clips), .. } else {
    fail("replay requires source provenance")
  }
  if source is { "dataset_sha256": String(digest), .. } {
    guard replay_payload_matches(
      experiment, "learning-transition-dataset", digest,
    ) else {
      fail("replay dataset is not sealed in this experiment")
    }
    // A retained dataset provides physical states only. A separate reference
    // track requires the registered reference evidence path below.
    for clip in clips {
      guard clip is { "tracks": Array(tracks), .. } &&
        tracks.all(track => track is { "kind": "physics", .. }) else {
        fail("retained-dataset replay cannot invent reference evidence")
      }
    }
  } else {
    guard source
      is {
        "study_sha256": String(study),
        "reference_manifest_sha256": String(manifest),
        ..
      } &&
      replay_payload_matches(experiment, "learning-reference-study", study) &&
      replay_payload_matches(
        experiment, "learning-reference-manifest", manifest,
      ) else {
      fail(
        "replay study and reference manifest are not sealed in this experiment",
      )
    }
    for clip in clips {
      guard clip
        is {
          "source": {
            "record_sha256": String(record),
            "reference_sha256": String(reference),
            ..
          },
          ..
        } &&
        replay_payload_matches(experiment, "learning-reference-physics", record) &&
        replay_payload_matches(experiment, "learning-reference-clip", reference) else {
        fail(
          "replay clip physics/reference evidence is not sealed in this experiment",
        )
      }
    }
  }
}

///|
/// An inexpensive availability hint for the experiment picker. Call
/// `read_replay` before displaying evidence; this does not verify recording bytes.
pub fn has_replay(root : String, id : String) -> Bool {
  if !valid_id(id) {
    return false
  }
  match @store.read_source(root, replay_source_id(id)) {
    Ok(source) =>
      source.kind == "learning-replay" &&
      source.source_id == replay_source_id(id)
    Err(_) => false
  }
}

///|
/// Read a registered full-body recording. The immutable parent experiment
/// summary, attachment, and recording bytes are verified before returning it.
pub fn read_replay(root : String, id : String) -> Result[Json, String] {
  try {
    let attachment = replay_attachment(root, id)
    let value = replay_validated_json(
      replay_blob_bytes(root, attachment.replay, 64 * 1024 * 1024),
      id,
    )
    replay_provenance(value, read_experiment(root, id))
    guard value is Object(fields) else { fail("invalid replay object") }
    // The artifact's exact original bytes remain sealed. This route projection
    // adds only the identity authenticated by its immutable parent summary.
    fields["experiment_id"] = Json(id)
    fields["physical_execution_allowed"] = false
    value
  } catch {
    error => Err(error.to_string())
  } noraise {
    value => Ok(value)
  }
}

///|
/// Resolve an experiment-bound mesh by its lowercase SHA-256 digest, returning
/// the exact bytes that were checked. Unregistered blobs are never served.
pub fn read_replay_asset(
  root : String,
  id : String,
  digest : String,
) -> Result[ReplayAsset, String] {
  try {
    guard replay_digest_is_valid(digest) else {
      fail("invalid replay asset digest")
    }
    let attachment = replay_attachment(root, id)
    let matches = attachment.assets.filter(ref_ => {
      ref_.checksum == "sha256:" + digest
    })
    guard matches.length() == 1 else {
      fail(
        "learning-replay-asset-unavailable: asset is not registered for this experiment",
      )
    }
    let ref_ = matches[0]
    guard ref_.content_type == "model/obj" else {
      fail("unsupported replay mesh content type")
    }
    ReplayAsset::{
      bytes: replay_blob_bytes(root, ref_, 32 * 1024 * 1024),
      content_type: ref_.content_type,
      checksum: ref_.checksum,
    }
  } catch {
    error => Err(error.to_string())
  } noraise {
    value => Ok(value)
  }
}

///|
fn replay_asset_names(value : Json) -> Array[(String, String)] raise {
  guard value is { "model": { "visuals": Array(visuals), .. }, .. } else {
    fail("replay has no model visuals")
  }
  let assets : Array[(String, String)] = []
  for visual in visuals {
    if visual
      is {
        "geometry": {
          "kind": "mesh",
          "asset": String(name),
          "sha256": String(digest),
          ..
        },
        ..
      } {
      guard replay_digest_is_valid(digest) && name == digest + ".obj" else {
        fail("replay mesh must use a content-addressed local OBJ filename")
      }
      if !assets.any(pair => pair.1 == digest) {
        assets.push((name, digest))
      }
    }
  }
  guard assets.length() <= 2048 else { fail("too many replay mesh assets") }
  assets
}

///|
fn attach_replay_impl(
  root : String,
  id : String,
  artifact_path : String,
  asset_root : String,
  now_ms : Int64,
) -> Json raise {
  let summary = replay_parent_summary(root, id)
  let size = need(@blob.local_file_size(artifact_path))
  guard size > 0L && size <= 64L * 1024L * 1024L else {
    fail("replay artifact exceeds the 64 MiB limit")
  }
  let bytes = need(
    @blob.read_local_file_range(artifact_path, 0L, size.to_int()),
  )
  let value = replay_validated_json(bytes, id)
  replay_provenance(value, read_experiment(root, id))
  let asset_names = replay_asset_names(value)
  let asset_sizes : Array[Int64] = []
  let mut total_size = 0L
  // Preflight the entire bounded input set before writing any blob. Rejected
  // provenance, oversized inputs, missing meshes and bad hashes have no storage
  // side effects. put_local_file checks the hash again during publication.
  for (name, digest) in asset_names {
    let path = asset_root + "/" + name
    let asset_size = need(@blob.local_file_size(path))
    guard asset_size > 0L && asset_size <= 32L * 1024L * 1024L else {
      fail("replay mesh exceeds the 32 MiB limit")
    }
    total_size += asset_size
    guard total_size <= 128L * 1024L * 1024L else {
      fail("replay meshes exceed the 128 MiB aggregate limit")
    }
    guard need(@blob.local_file_checksum(path)) == "sha256:" + digest else {
      fail("replay mesh checksum mismatch")
    }
    asset_sizes.push(asset_size)
  }
  if @fsx.path_exists(@store.source_path(root, replay_source_id(id))) {
    let previous = replay_attachment(root, id)
    guard previous.replay.checksum == @data.bytes_checksum(bytes) &&
      previous.replay.byte_count == size &&
      previous.assets.length() == asset_names.length() else {
      fail("experiment already has a different immutable replay attachment")
    }
    for index, (_, digest) in asset_names {
      let asset = previous.assets[index]
      guard asset.checksum == "sha256:" + digest &&
        asset.byte_count == asset_sizes[index] else {
        fail("experiment already has different immutable replay assets")
      }
      ignore(replay_blob_bytes(root, asset, 32 * 1024 * 1024))
    }
    ignore(replay_blob_bytes(root, previous.replay, 64 * 1024 * 1024))
    ignore(need(@index.rebuild_catalog(root, now_ms)))
    return value
  }
  let refs : Array[@data.DataRef] = []
  for (name, digest) in asset_names {
    let path = asset_root + "/" + name
    refs.push(
      need(
        @blob.put_local_file(
          root,
          path,
          kind="learning-replay-asset",
          content_type="model/obj",
          expected_checksum="sha256:" + digest,
        ),
      ).data_ref,
    )
  }
  let replay = need(
      @blob.put_local_bytes(
        root,
        bytes,
        kind="learning-pose-replay",
        content_type="application/json",
      ),
    ).data_ref
  // Detect another publisher before writing its source. Validated immutable
  // blobs can be shared, so an interrupted import never deletes them in rollback.
  // A catalog-write failure is recoverable by idempotently reattaching the same
  // recording; it does not modify any original experiment or recording bytes.
  if @fsx.path_exists(@store.source_path(root, replay_source_id(id))) {
    let previous = replay_attachment(root, id)
    guard previous.replay == replay && previous.assets == refs else {
      fail("experiment already has a different immutable replay attachment")
    }
    ignore(need(@index.rebuild_catalog(root, now_ms)))
    return value
  }
  let attachment : ReplayAttachment = {
    format: "moonrobo.learning-replay-attachment.v1",
    experiment_id: id,
    experiment_summary: summary,
    replay,
    assets: refs,
  }
  let envelope = need(
      @blob.put_local_bytes(
        root,
        @utf8.encode(attachment.to_json().stringify(indent=2)),
        kind="learning-replay-attachment",
        content_type="application/json",
      ),
    ).data_ref
  let source_refs = [envelope, summary, replay]
  source_refs.append(refs)
  let source = @data.data_source(
    replay_source_id(id),
    "learning-replay",
    "3D replay for " + id,
    "g1-simulation",
    "recorded-pose-channel",
    "file://" + artifact_path,
    now_ms,
    source_refs~,
  )
  ignore(need(@store.write_source(root, source)))
  ignore(need(@index.rebuild_catalog(root, now_ms)))
  value
}

///|
/// Seal a replay and content-addressed OBJ assets beside an existing immutable
/// experiment. Existing experiments and Python artifacts are never rewritten.
/// The same recording can be attached repeatedly; changed bytes are rejected.
/// Registry v1 accepts the native producer's OBJ meshes only, bounded to 32 MiB
/// each and 128 MiB per model to match the browser renderer's resource limits.
pub fn attach_replay(
  root : String,
  id : String,
  artifact_path : String,
  asset_root~ : String,
  now_ms~ : Int64 = 0L,
) -> Result[Json, String] {
  try attach_replay_impl(root, id, artifact_path, asset_root, now_ms) catch {
    error => Err(error.to_string())
  } noraise {
    value => Ok(value)
  }
}
