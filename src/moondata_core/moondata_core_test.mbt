///|
test "quality run status follows blocker and warning counts" {
  let findings = [
    @moondata_core.quality_finding(
      "find-1", "missing-frame", "blocker", "episode", "ep-1", "missing frame",
    ),
    @moondata_core.quality_finding(
      "find-2", "timestamp-gap", "warning", "frame", "frame-2", "large gap",
    ),
  ]
  let run = @moondata_core.quality_run("qr-1", "ds-1", ["ep-1"], 10L, findings)
  assert_eq(run.status, "blocked")
  assert_eq(run.finding_count, 2)
  assert_eq(run.blocker_count, 1)
  assert_eq(run.warning_count, 1)
}

///|
test "manifest json exposes stable ids" {
  let dataset = @moondata_core.dataset_manifest(
    "ds-noetix-1",
    "canonical",
    "active",
    42L,
    source_ids=["src-1"],
    capture_ids=["cap-1"],
    episode_ids=["ep-1"],
  )
  let text = @moondata_core.dataset_json(dataset)
  assert_true(text.contains("\"dataset_id\": \"ds-noetix-1\""))
  assert_true(text.contains("\"episode_ids\""))
}

///|
test "version transform and export contracts share ids" {
  let version = @moondata_core.dataset_version(
    "version-a",
    "dataset-curated",
    "accepted",
    42L,
    parent_version_ids=["version-parent"],
    accepted_episode_ids=["episode-a"],
    quality_run_ids=["quality-a"],
    summary="accepted for evaluation",
  )
  let step = @moondata_core.transform_step(
    "step-a",
    "drop-rejected",
    "{}",
    summary="keep accepted episodes",
  )
  let run = @moondata_core.transform_run(
    "transform-a",
    "dataset-raw",
    version.dataset_id,
    42L,
    [step],
    quality_run_ids=version.quality_run_ids,
    lineage_id="lineage-a",
  )
  let output = @moondata_core.data_ref(
    "export-a-ref",
    "dataset-export",
    "moondata://exports/export-a.jsonl",
    content_type="application/jsonl",
  )
  let manifest = @moondata_core.export_manifest(
    "export-a",
    version.version_id,
    version.dataset_id,
    "jsonl",
    "{\"frame\":\"payload\"}",
    [output],
    43L,
    quality_run_ids=version.quality_run_ids,
  )
  assert_eq(run.output_dataset_id, manifest.dataset_id)
  assert_eq(manifest.input_version_id, version.version_id)
  assert_eq(run.step_count, 1)
}

///|
test "catalog exposes bounded moondata refs" {
  let entry = @moondata_core.catalog_entry(
    "dataset",
    "dataset-a",
    "datasets/canonical/dataset-a.json",
    status="active",
    summary="canonical dataset",
  )
  let catalog = @moondata_core.moondata_catalog("moondata", 50L, [entry])
  let refs = @moondata_core.catalog_refs(catalog)
  assert_eq(catalog.entry_count, 1)
  assert_eq(refs[0].artifact_kind, "dataset")
  assert_eq(refs[0].artifact_id, "dataset-a")
}

///|
test "robot model manifest carries durable model payload refs" {
  let urdf_ref = @moondata_core.data_ref(
    "robot-model-urdf",
    "urdf",
    "moondata://media/robot_models/noetix-e1/robot.urdf",
    content_type="application/xml",
    byte_count=23L,
    checksum="text-sum-v1:23:401",
  )
  let mesh_ref = @moondata_core.data_ref(
    "robot-model-base-mesh",
    "stl",
    "moondata://media/robot_models/noetix-e1/meshes/base.stl",
    byte_count=29L,
    checksum="text-sum-v1:29:402",
  )
  let model = @moondata_core.robot_model_manifest(
    "model-noetix-e1",
    "noetix-e1-lab-01",
    "urdf",
    "active",
    urdf_ref,
    70L,
    mesh_refs=[mesh_ref],
    link_names=["base_link"],
    joint_names=["hip_yaw"],
    provenance="operator import",
    validation_status="passed",
    summary="Noetix E1 URDF model",
  )
  assert_eq(model.model_id, "model-noetix-e1")
  assert_eq(model.urdf_ref.kind, "urdf")
  assert_eq(model.mesh_refs[0].kind, "stl")
  assert_eq(model.link_names[0], "base_link")
  assert_eq(model.joint_names[0], "hip_yaw")
}

///|
test "text checksum is stable for payload refs" {
  assert_eq(
    @moondata_core.text_checksum("{\"t\":1}"),
    "text-sum-v1:7:193761392",
  )
}

///|
test "bytes checksum is stable for binary payload refs" {
  let bytes = Bytes::makei(3, fn(index) { (97 + index).to_byte() })
  assert_eq(@moondata_core.bytes_checksum(bytes), "bytes-sum-v1:3:295000119")
}

///|
test "moondata uri helpers keep payload refs relative and scoped" {
  assert_eq(
    @moondata_core.moondata_uri("media/imports/ds/frame.json"),
    "moondata://media/imports/ds/frame.json",
  )
  assert_true(
    @moondata_core.moondata_relative_path_is_safe("media/imports/ds/frame.json"),
  )
  assert_false(@moondata_core.moondata_relative_path_is_safe("../escape.json"))
  assert_false(
    @moondata_core.moondata_relative_path_is_safe("media/imports//frame.json"),
  )
  match
    @moondata_core.moondata_payload_uri_relative_path(
      "moondata://media/imports/ds/frame.json",
    ) {
    Some(relative) => assert_eq(relative, "media/imports/ds/frame.json")
    None => fail("expected payload uri to resolve")
  }
  match
    @moondata_core.moondata_payload_uri_relative_path(
      "moondata://indexes/catalog.json",
    ) {
    Some(_) => fail("expected non-payload uri to be rejected")
    None => ()
  }
  match
    @moondata_core.moondata_uri_path(
      "root", "moondata://media/replays/run.json",
    ) {
    Some(path) => assert_eq(path, "root/media/replays/run.json")
    None => fail("expected moondata uri path")
  }
}
