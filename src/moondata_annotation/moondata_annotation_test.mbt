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
}
