///|
fn replay_registry_fixture(root : String) -> (String, Json, String) raise {
  clear_learning_fixture(root)
  @fsx.create_dir(root)
  let store = root + "/moondata"
  let bytes = b"v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n"
  let mesh_hash = @data.bytes_checksum(bytes)
    .strip_prefix("sha256:")
    .unwrap()
    .to_owned()
  @fsx.create_dir(root + "/assets")
  @fsx.write_bytes_to_file(root + "/assets/" + mesh_hash + ".obj", bytes)
  let payloads : Array[@moondata_learning.LearningPayload] = []
  let hashes : Array[String] = []
  for
    (name, kind) in [
      ("study", "learning-reference-study"),
      ("manifest", "learning-reference-manifest"),
      ("record", "learning-reference-physics"),
      ("reference", "learning-reference-clip"),
    ] {
    let ref_ = @blob.put_local_bytes(store, @utf8.encode(name), kind~).unwrap().data_ref
    payloads.push({ relative_path: name, data_ref: ref_, })
    hashes.push(ref_.checksum.strip_prefix("sha256:").unwrap().to_owned())
  }
  let summary : @moondata_learning.LearningExperiment = {
    format: "moonrobo.learning-experiment.v1",
    experiment_id: "fixture",
    source_id: "learning-fixture",
    imported_at_ms: 1L,
    evidence_class: "physics-simulation",
    physical_execution_allowed: false,
    candidates: [],
    payloads,
  }
  let summary_ref = @blob.put_local_bytes(
      store,
      @utf8.encode(summary.to_json().stringify()),
      kind="learning-summary",
    ).unwrap().data_ref
  let refs = [summary_ref]
  refs.append(payloads.map(payload => payload.data_ref))
  ignore(
    @store.write_source(
      store,
      @data.data_source(
        "learning-fixture",
        "learning-experiment",
        "Fixture",
        "g1",
        "mujoco",
        "file://fixture",
        1L,
        source_refs=refs,
      ),
    ).unwrap(),
  )
  ignore(@index.rebuild_catalog(store, 1L).unwrap())
  let pose : Json = {
    "time_s": 0,
    "bodies": [
      { "body_id": "0", "position": [0, 0, 1], "quaternion_wxyz": [1, 0, 0, 0] },
    ],
  }
  let replay : Json = {
    "format": "moonrobo.pose-replay.v1",
    "model": {
      "id": "fixture-model",
      "sha256": Json(mesh_hash),
      "coordinate_system": "right-handed-z-up",
      "bodies": [{ "id": "0", "name": "root", "parent_id": Json::null() }],
      "visuals": [
        {
          "id": "mesh",
          "body_id": "0",
          "geometry": {
            "kind": "mesh",
            "asset": Json(mesh_hash + ".obj"),
            "sha256": Json(mesh_hash),
            "scale": [1, 1, 1],
          },
          "local_position": [0, 0, 0],
          "local_quaternion_wxyz": [1, 0, 0, 0],
          "rgba": [1, 1, 1, 1],
        },
      ],
    },
    "source": {
      "study_sha256": Json(hashes[0]),
      "reference_manifest_sha256": Json(hashes[1]),
    },
    "clips": [
      {
        "id": "stand",
        "label": "Standing",
        "source_start_time_s": 0,
        "source": {
          "record_sha256": Json(hashes[2]),
          "reference_sha256": Json(hashes[3]),
        },
        "tracks": [
          {
            "id": "physics",
            "kind": "physics",
            "label": "Physics",
            "frames": [pose],
          },
          {
            "id": "reference",
            "kind": "reference",
            "label": "Reference",
            "frames": [pose],
          },
        ],
      },
    ],
  }
  @fsx.write_string_to_file(root + "/replay.json", replay.stringify())
  (store, replay, mesh_hash)
}

///|
test "replay attachment preserves original registry and survives original-file removal" {
  let root = "target/learning-replay-registration-test"
  let (store, expected, mesh_hash) = replay_registry_fixture(root)
  let original = @fsx.read_file_to_bytes(
    @store.source_path(store, "learning-fixture"),
  )
  assert_false(@moondata_learning.has_replay(store, "fixture"))
  assert_true(
    @moondata_learning.read_replay(store, "fixture") is Err(message) &&
    message.contains("learning-replay-unavailable"),
  )
  let first = match
    @moondata_learning.attach_replay(
      store,
      "fixture",
      root + "/replay.json",
      asset_root=root + "/assets",
      now_ms=2L,
    ) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  assert_eq(first, expected)
  assert_eq(
    @moondata_learning.attach_replay(
      store,
      "fixture",
      root + "/replay.json",
      asset_root=root + "/assets",
      now_ms=3L,
    ).unwrap(),
    expected,
  )
  assert_eq(
    @fsx.read_file_to_bytes(@store.source_path(store, "learning-fixture")),
    original,
  )
  assert_true(@moondata_learning.has_replay(store, "fixture"))
  assert_eq(@moondata_learning.list(store).unwrap().length(), 1)
  clear_learning_fixture(root + "/assets")
  @fsx.remove_file(root + "/replay.json")
  let reopened = @moondata_learning.read_replay(store, "fixture").unwrap()
  assert_true(
    reopened
    is { "experiment_id": "fixture", "physical_execution_allowed": False, .. },
  )
  let asset = @moondata_learning.read_replay_asset(store, "fixture", mesh_hash).unwrap()
  assert_eq(asset.checksum, "sha256:" + mesh_hash)
  assert_eq(asset.content_type, "model/obj")
  assert_true(
    @moondata_learning.read_replay_asset(store, "fixture", "../elsewhere")
    is Err(_),
  )
  assert_true(
    @moondata_learning.read_replay_asset(
      store, "fixture", "0000000000000000000000000000000000000000000000000000000000000000",
    )
    is Err(_),
  )
  let blob_path = store +
    "/blobs/sha256/" +
    mesh_hash[:2].to_owned() +
    "/" +
    mesh_hash
  @fsx.write_bytes_to_file(blob_path, b"corrupted")
  assert_true(
    @moondata_learning.read_replay_asset(store, "fixture", mesh_hash) is Err(_),
  )
}

///|
test "replay registration rejects unrelated provenance and immutable replacement" {
  let root = "target/learning-replay-provenance-test"
  let (store, expected, _) = replay_registry_fixture(root)
  guard expected is Object(fields) else { fail("fixture") }
  fields["source"] = {
    "study_sha256": "0000000000000000000000000000000000000000000000000000000000000000",
    "reference_manifest_sha256": "0000000000000000000000000000000000000000000000000000000000000000",
  }
  @fsx.write_string_to_file(root + "/unrelated.json", expected.stringify())
  assert_true(
    @moondata_learning.attach_replay(
      store,
      "fixture",
      root + "/unrelated.json",
      asset_root=root + "/assets",
    )
    is Err(_),
  )
  assert_false(@moondata_learning.has_replay(store, "fixture"))
  ignore(
    @moondata_learning.attach_replay(
      store,
      "fixture",
      root + "/replay.json",
      asset_root=root + "/assets",
    ).unwrap(),
  )
  let changed = @json.parse(@fsx.read_file_to_string(root + "/replay.json"))
  guard changed is Object(changed_fields) else { fail("fixture") }
  changed_fields["note"] = "replacement bytes"
  @fsx.write_string_to_file(root + "/changed.json", changed.stringify())
  assert_true(
    @moondata_learning.attach_replay(
      store,
      "fixture",
      root + "/changed.json",
      asset_root=root + "/assets",
    )
    is Err(_),
  )
}
