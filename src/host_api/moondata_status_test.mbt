///|
test "MoonData status is a stable read-only projection before initialization" {
  let root = "/tmp/moonrobo-moondata-status-missing-root"
  let status = @host_api.moondata_cockpit_status(root).unwrap()
  assert_eq(status.initialized, false)
  assert_eq(status.status, "not-initialized")
  assert_eq(status.artifact_count, 0)
  assert_eq(status.root, root + "/moondata")
  let response = @host_api.route(root, "GET", @host_api.moondata_status_path())
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"initialized\": false"))
  assert_true(response.body.contains("\"status\": \"not-initialized\""))
  assert_true(response.body.contains("\"artifacts\": []"))
}

///|
test "learning experiments are a read-only projection before initialization" {
  let root = "/tmp/moonrobo-learning-missing-root"
  let response = @host_api.route(
    root,
    "GET",
    @host_api.learning_experiments_path(),
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"initialized\": false"))
  assert_true(response.body.contains("\"experiments\": []"))
  assert_true(response.body.contains("\"physical_execution_allowed\": false"))
  assert_true(!@fsx.path_exists(root))
}

///|
test "learning route projects registered evidence from the selected workspace" {
  let root = "target/learning-host-projection-test"
  let data_root = @host_api.moondata_root_for_robobook(root)
  let report : Json = {
    "baseline": { "trials": [] },
    "candidate": { "trials": [] },
  }
  let physics = @moondata_blob.put_local_bytes(
    data_root,
    @utf8.encode(report.stringify()),
    kind="learning-physics-trace",
  ).unwrap()
  let checkpoint = @moondata_blob.put_local_bytes(
    data_root,
    b"weights",
    kind="learning-policy-checkpoint",
  ).unwrap()
  let stats : @moondata_learning.TrialSummary = {
    trials: 9,
    falls: 9,
    mean_survival_s: 1.24,
    mean_joint_rmse_rad: 0.097,
  }
  let summary : @moondata_learning.LearningExperiment = {
    format: "moonrobo.learning-experiment.v1",
    experiment_id: "round-one",
    source_id: "learning-round-one",
    imported_at_ms: 10L,
    evidence_class: "physics-simulation",
    physical_execution_allowed: false,
    candidates: [
      {
        seed: 0,
        selected_update: 0,
        baseline: stats,
        candidate: stats,
        survival_delta_s: 0.0,
        producer_qualified: false,
        checkpoint_ref: checkpoint.data_ref,
      },
    ],
    payloads: [
      {
        relative_path: "policy/physics-seed-0.json",
        data_ref: physics.data_ref,
      },
    ],
  }
  let blob = @moondata_blob.put_local_bytes(
    data_root,
    @utf8.encode(summary.to_json().stringify()),
    kind="learning-summary",
  ).unwrap()
  let source = @moondata_core.data_source(
    summary.source_id,
    "learning-experiment",
    "Learning test",
    "g1-simulation",
    "mujoco-cpu",
    "file://fixture",
    10L,
    source_refs=[blob.data_ref, physics.data_ref, checkpoint.data_ref],
  )
  ignore(@moondata_store.write_source(data_root, source).unwrap())
  ignore(@moondata_index.rebuild_catalog(data_root, 20L).unwrap())
  let catalog_path = @moondata_store.catalog_path(data_root)
  let before = @fsx.read_file_to_string(catalog_path)
  let response = @host_api.route(
    root,
    "GET",
    @host_api.learning_experiments_path(),
  )
  assert_eq(response.status, 200, msg=response.body)
  guard @json.parse(response.body)
    is { "initialized": True, "experiments": Array(rows), .. } else {
    fail("expected initialized experiment list")
  }
  assert_eq(rows.length(), 1)
  assert_eq(
    (@json.from_json(rows[0]) : @moondata_learning.LearningExperiment),
    summary,
  )
  assert_eq(@fsx.read_file_to_string(catalog_path), before)
  let physics_path = @host_api.learning_experiments_path() +
    "/round-one/physics/0"
  let response = @host_api.route(root, "GET", physics_path)
  assert_eq(response.status, 200, msg=response.body)
  let evidence : @moondata_learning.LearningPhysics = @json.from_json(
    @json.parse(response.body),
  )
  assert_eq(evidence.report, report)
  assert_eq(evidence.data_ref, physics.data_ref)
  assert_eq(evidence.physical_execution_allowed, false)
  assert_eq(
    @host_api.route(root, "GET", physics_path + "/fresh-ten-second").status,
    400,
  )
  assert_eq(
    @host_api.route(
      root,
      "GET",
      @host_api.learning_experiments_path() + "/round-one/physics/no-seed",
    ).status,
    400,
  )
  @fsx.write_string_to_file(physics.path, "{}")
  let corrupt = @host_api.route(root, "GET", physics_path)
  @fsx.write_string_to_file(physics.path, report.stringify())
  assert_eq(corrupt.status, 400)
  assert_true(corrupt.body.contains("checksum mismatch"))
}
