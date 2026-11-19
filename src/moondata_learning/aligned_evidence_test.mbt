///|
test "aligned smoke seals original metrics without inventing a matched baseline" {
  let root = "target/learning-aligned-registration-test"
  let run = learning_fixture(root, false)
  let checkpoint = run + "/checkpoint.pt"
  @fsx.write_bytes_to_file(checkpoint, b"aligned numerical fixture")
  let sha = reference_fixture_sha(checkpoint)
  let report : Json = {
    "format": "moonrobo.supermimic-aligned-training.v1",
    "profile": "cpu-smoke",
    "checkpoint_sha256": Json(sha),
    "identity": { "backend": "mujoco", "motion_count": 40 },
    "counters": { "actor_updates": 2 },
  }
  let evaluation : Json = {
    "format": "moonrobo.supermimic-full-clip-evaluation.v1",
    "checkpoint_sha256": Json(sha),
    "identity": { "backend": "mujoco", "motion_count": 40 },
    "n_clips": 40,
    "n_failed": 40,
    "norm_return": 0.01,
  }
  @fsx.write_string_to_file(run + "/report.json", report.stringify())
  @fsx.write_string_to_file(run + "/evaluation.json", evaluation.stringify())
  let native_export : Json = {
    "format": "moonrobo.aligned-native-export.v1",
    "native_validation_passed": true,
    "physical_execution_allowed": false,
    "checkpoint_sha256": Json(sha),
    "dataset_sha256": Json(
      reference_fixture_sha(run + "/collection/dataset.json"),
    ),
  }
  @fsx.write_string_to_file(
    run + "/native-export.json",
    native_export.stringify(),
  )
  let store = root + "/moondata"
  let imported = @moondata_learning.import_run(store, run, "aligned", 10L).unwrap()
  assert_eq(imported.evidence_class, "physics-simulation-method-smoke")
  assert_true(imported.candidates.is_empty())
  assert_false(imported.physical_execution_allowed)
  assert_eq(imported.payloads.length(), 5)
  assert_eq(
    @moondata_learning.import_run(store, run, "aligned", 20L).unwrap(),
    imported,
  )
  let protocol_report : Json = {
    "format": "moonrobo.supermimic-aligned-training.v1",
    "profile": "smc-protocol-cpu-check",
    "checkpoint_sha256": Json(sha),
    "identity": { "backend": "mujoco", "motion_count": 40 },
    "counters": { "actor_updates": 10 },
  }
  @fsx.write_string_to_file(run + "/report.json", protocol_report.stringify())
  let protocol = @moondata_learning.import_run(store, run, "protocol", 20L).unwrap()
  assert_eq(protocol.evidence_class, "physics-simulation-method-smoke")
  assert_true(protocol.candidates.is_empty())
  @fsx.write_bytes_to_file(checkpoint, b"changed")
  assert_true(@moondata_learning.import_run(store, run, "other", 20L) is Err(_))
  clear_learning_fixture(run)
  assert_eq(@moondata_learning.inspect(store, "aligned").unwrap(), imported)
  assert_eq(
    @validate.validate_root(store, generated_at_ms=30L).unwrap().status,
    "passed",
  )
}
