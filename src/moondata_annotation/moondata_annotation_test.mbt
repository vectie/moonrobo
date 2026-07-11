///|
test "annotation set indexes target ids" {
  let target = @moondata_core.moondata_ref(
    "frame", "frame-1", "frames/frame-1.json", "reviewed frame",
  )
  let label = @moondata_core.annotation_label("surface", "slippery")
  let set = @moondata_annotation.review_annotation_set(
    "ann-1",
    [target],
    [label],
    "operator",
    30L,
  )
  assert_eq(set.status, "accepted")
  assert_eq(@moondata_annotation.target_ids(set)[0], "frame-1")
  assert_eq(
    @moondata_annotation.annotation_target_index_id(set.annotation_set_id),
    "annotation-target-ann-1",
  )
  let index = @moondata_annotation.review_target_index("ann-index-1", set)
  assert_eq(index.annotation_index_id, "ann-index-1")
  assert_eq(index.annotation_set_id, "ann-1")
  assert_eq(index.target_refs[0].artifact_id, "frame-1")
  assert_eq(index.label_keys[0], "surface")
  assert_eq(index.label_values[0], "slippery")
  assert_eq(index.reviewer, "operator")
}
