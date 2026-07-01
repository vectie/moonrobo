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
