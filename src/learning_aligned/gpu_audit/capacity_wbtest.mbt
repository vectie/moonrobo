///|
fn[T] capacity_rejected(action : () -> T raise) -> Bool {
  try {
    ignore(action())
    false
  } catch {
    _ => true
  }
}

///|
test "audit capacity is explicit and preserves initial file and world limits" {
  assert_eq(requested_capacity([]), @capacity.Initial)
  assert_eq(
    requested_capacity(["--capacity-profile", "initial"]),
    @capacity.Initial,
  )
  assert_eq(
    requested_capacity(["--capacity-profile", "paper-4096"]),
    @capacity.Paper4096,
  )
  for
    args in [
      ["--capacity-profile"],
      ["--capacity-profile", "paper4096"],
      ["--capacity-profile", "Paper-4096"],
      ["--capacity-profile", "initial", "--capacity-profile", "paper-4096"],
    ] {
    assert_true(capacity_rejected(() => requested_capacity(args)))
  }
  let initial = audit_capacity(@capacity.Initial)
  assert_eq(initial.worlds, 128)
  assert_eq(initial.tape_bytes, 4194304L)
  assert_eq(initial.manifest_bytes, 4194304L)
  assert_eq(initial.payload_file_bytes, 268435456L)
  assert_eq(initial.payload_total_bytes, 1073741824L)
  assert_eq(initial.numeric_union_bytes, 536870912L)
  assert_eq(initial.file_entries, 8192)
  assert_eq(initial.region_entries, 8192)
  let paper = audit_capacity(@capacity.Paper4096)
  assert_eq(paper.worlds, 4096)
  assert_eq(paper.tape_bytes, 67108864L)
  assert_eq(paper.manifest_bytes, 67108864L)
  assert_eq(paper.payload_file_bytes, 1073741824L)
  assert_eq(paper.payload_total_bytes, 4294967296L)
  assert_eq(paper.numeric_union_bytes, 2147483648L)
  assert_eq(paper.file_entries, 4096)
  assert_eq(paper.region_entries, 8192)
  validate_selected_count(128, @capacity.Initial)
  validate_selected_count(4096, @capacity.Paper4096)
  assert_true(
    capacity_rejected(() => validate_selected_count(129, @capacity.Initial)),
  )
  assert_true(
    capacity_rejected(() => validate_selected_count(4097, @capacity.Paper4096)),
  )
  assert_true(
    capacity_rejected(() => validate_selected_count(3, @capacity.Paper4096)),
  )
  @gpu.validate_audit_worlds(4096, [0, 2048, 4095], capacity_profile=Paper4096)
  assert_true(
    capacity_rejected(() => @gpu.validate_audit_worlds(4096, [0, 2048, 4095])),
  )
}

///|
test "manifest cannot upgrade audit capacity and tape schema stays unchanged" {
  validate_manifest_capacity({ "num_envs": 4 }, @capacity.Initial)
  validate_manifest_capacity(
    { "capacity_profile": "initial" },
    @capacity.Initial,
  )
  validate_manifest_capacity(
    { "capacity_profile": "paper-4096" },
    @capacity.Paper4096,
  )
  let invalid : Array[Json] = [
    { "capacity_profile": "paper-4096" },
    { "capacity_profile": "unknown" },
    { "capacity_profile": Json::null() },
    { "capacity_profile": true },
  ]
  for bad in invalid {
    assert_true(
      capacity_rejected(() => validate_manifest_capacity(bad, @capacity.Initial)),
    )
  }
  assert_true(
    capacity_rejected(() => validate_manifest_capacity({}, @capacity.Paper4096)),
  )
  let initial = selected_tape(4)
  let paper = selected_tape(4, capacity_profile=Paper4096)
  assert_eq(Json(initial).stringify(indent=2), Json(paper).stringify(indent=2))
  paper.validate(capacity_profile=Paper4096)
  let fake_large = {
    ..paper,
    num_envs: 4096,
    selected_worlds: Some([0, 2048, 4095]),
  }
  // Profile metadata cannot waive full-world input dimensions/reset coverage.
  assert_true(
    capacity_rejected(() => fake_large.validate(capacity_profile=Paper4096)),
  )
}

///|
test "audit arithmetic and metadata headroom reject overflow without large allocations" {
  assert_eq(audit_size_add(3221225472L, 1073741824L, 4294967296L), 4294967296L)
  for
    (total, value, maximum) in [
      (4294967296L, 1L, 4294967296L),
      (9223372036854775807L, 1L, 9223372036854775807L),
      (0L, 0L, 1073741824L),
      (-1L, 1L, 1073741824L),
    ] {
    assert_true(capacity_rejected(() => audit_size_add(total, value, maximum)))
  }
  require_json_headroom(67108864L, 2147483648L)
  assert_true(
    capacity_rejected(() => require_json_headroom(67108864L, 1073741824L)),
  )
  assert_true(
    capacity_rejected(() => {
      require_json_headroom(67108865L, 9223372036854775807L)
    }),
  )
  assert_true(capacity_rejected(() => require_json_headroom(1L, 0L)))
}
