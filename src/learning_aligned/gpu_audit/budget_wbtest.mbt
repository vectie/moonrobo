///|
test "audit shared region accepts exact producer numbers and legacy decimal strings" {
  let initial = audit_capacity(@capacity.Initial)
  let paper = audit_capacity(@capacity.Paper4096)
  for
    (value, expected) in [
      (Json(36864), 36864L),
      (Json("36864"), 36864L),
      (Json(1), 1L),
      (Json("1"), 1L),
      (Json(268435456), 268435456L),
      (Json("268435456"), 268435456L),
    ] {
    assert_eq(audit_region_bytes(value, initial.payload_file_bytes), expected)
    assert_eq(audit_region_bytes(value, paper.payload_file_bytes), expected)
  }
  assert_eq(
    audit_region_bytes(Json(1073741824), paper.payload_file_bytes),
    1073741824L,
  )
  assert_eq(
    audit_region_bytes(Json("1073741824"), paper.payload_file_bytes),
    1073741824L,
  )
  assert_eq(
    audit_shared_region_bytes(
      [{ "bytes": 1073741824 }, { "bytes": "1073741824" }],
      paper,
    ),
    2147483648L,
  )
}

///|
test "audit shared region rejects fractional invalid and out-of-bound byte counts" {
  let paper = audit_capacity(@capacity.Paper4096)
  let bad : Array[Json] = [
    Json(1.25),
    Json(0),
    Json(-1),
    Json(1073741825),
    Json(9007199254740992.0),
    Json(1.0 / 0.0),
    Json(0.0 / 0.0),
    Json("0"),
    Json("-1"),
    Json("1.25"),
    Json("1073741825"),
    Json("9223372036854775808"),
    Json("1e2"),
    Json("+1"),
    Json(" 1"),
    Json("1 "),
    Json(""),
    Json::null(),
    Json(true),
    Json([]),
    Json({}),
  ]
  for value in bad {
    assert_true(
      capacity_rejected(() => {
        audit_region_bytes(value, paper.payload_file_bytes)
      }),
    )
  }
  assert_true(
    capacity_rejected(() => {
      audit_region_bytes(
        Json(268435457),
        audit_capacity(@capacity.Initial).payload_file_bytes,
      )
    }),
  )
  assert_true(
    capacity_rejected(() => {
      audit_shared_region_bytes(
        [{ "bytes": 1073741824 }, { "bytes": 1073741824 }, { "bytes": 1 }],
        paper,
      )
    }),
  )
  assert_true(capacity_rejected(() => audit_shared_region_bytes([{}], paper)))
}

///|
async test "actual frozen N256 metadata decodes before CUDA and preserves region union" {
  // These are byte-for-byte metadata from the successful N256 authoring/oracle
  // run, not graph payloads or fabricated JSON. No CUDA handle is opened here.
  let root = "src/learning_aligned/gpu_audit/testdata/paper-n256-20261024-b/"
  let (manifest, manifest_sha) = read_json_hashed(
    root + "manifest.json",
    67108864L,
  )
  let (tape_json, tape_sha) = read_json_hashed(root + "tape.json", 67108864L)
  let (oracle_json, oracle_sha) = read_json_hashed(
    root + "oracle.json",
    16777216L,
  )
  assert_eq(
    manifest_sha, "40e166ab973ba7ae11c2587a9e26d990f52b77d10ef230caee303e06203ae2e8",
  )
  assert_eq(
    tape_sha, "d34e9722f74d1b896bb797e74832e29e8bae07ba5268ac31a2a65c27d8a55860",
  )
  assert_eq(
    oracle_sha, "2e2f434dd18ca9237200d9e5ab740d3e639b8040a0ee060b831eaf398b387481",
  )
  validate_manifest_capacity(manifest, @capacity.Paper4096)
  validate_manifest_capacity(oracle_json, @capacity.Paper4096)
  let tape : Tape = @json.from_json(tape_json)
  tape.validate(capacity_profile=Paper4096)
  let oracle : Oracle = @json.from_json(oracle_json)
  oracle.validate_selection(tape)
  assert_eq(tape.num_envs, 256)
  assert_eq(tape.selected_worlds, Some([0, 128, 255]))
  assert_eq(tape.operations.length(), 27)
  assert_eq(oracle.snapshots.length(), tape.operations.length())
  assert_eq(oracle.bundle_manifest_sha256, manifest_sha)
  assert_eq(oracle.tape_sha256, tape_sha)
  for i, snapshot in oracle.snapshots {
    assert_eq(snapshot.id, tape.operations[i].id)
    validate_readback(snapshot.readback, 3)
  }
  guard manifest is { "shared_regions": Array(regions), .. } else {
    fail("frozen N256 shared regions missing")
  }
  assert_eq(regions.length(), 333)
  assert_true(regions[0] is { "bytes": Number(36864.0), .. })
  assert_eq(
    audit_shared_region_bytes(regions, audit_capacity(@capacity.Paper4096)),
    54331573L,
  )
}
