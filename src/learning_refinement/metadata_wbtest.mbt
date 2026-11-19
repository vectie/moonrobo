///|
/// Deferred regression source; no workflow/test was executed during migration.
test "refinement keeps actual parent ancestry and current selection without inherited stale critic" {
  let parent : Json = {
    "model_ref": "actual-model-digest",
    "base_config": { "hidden_width": 4 },
    "temporal_value_checkpoint": { "stale": true },
  }
  let current : Json = {
    "config": { "updates": 10 },
    "selected_update": 3,
    "initialization": { "sha256": "actual-parent-bytes" },
  }
  let metadata = inherit_temporal_metadata(parent, current)
  assert_eq(field(metadata, "model_ref"), "actual-model-digest".to_json())
  assert_eq(field(metadata, "base_config"), field(parent, "base_config"))
  assert_eq(field(metadata, "selected_update"), (3).to_json())
  guard metadata is Object(fields) else { fail("metadata must be object") }
  assert_true(!fields.contains("temporal_value_checkpoint"))
  assert_true(
    (try? inherit_temporal_metadata({ "base_config": {} }, current)) is Err(_),
  )
}
