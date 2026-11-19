///|
test "audit selects exactly one generation or the existing pair mode" {
  assert_eq(
    audit_mode(["audit", "--generation", "/data/generation-1"]),
    Generation("/data/generation-1"),
  )
  assert_eq(
    audit_mode(["audit", "--right", "/data/rank1", "--left", "/data/rank0"]),
    Pair("/data/rank0", "/data/rank1"),
  )
}

///|
test "audit refuses mixed incomplete duplicate or missing mode arguments" {
  for
    args in [
      [],
      ["--left", "/data/left"],
      ["--right", "/data/right"],
      ["--generation"],
      ["--generation", ""],
      ["--generation", "--tensor-library", "/library"],
      ["--generation", "/data/one", "--left", "/data/left"],
      ["--generation", "/data/one", "--right", "/data/right"],
      [
        "--generation", "/data/one", "--left", "/data/left", "--right", "/data/right",
      ],
      ["--generation", "/data/one", "--generation", "/data/two"],
      ["--left", "/data/a", "--left", "/data/b", "--right", "/data/c"],
      ["--left", "/data/a", "--right", "/data/b", "--right", "/data/c"],
    ] {
    try audit_mode(args) catch {
      _ => ()
    } noraise {
      _ => fail("ambiguous or incomplete audit mode must fail closed")
    }
  }
}

///|
test "single generation report retains attestation evidence without equality claims" {
  let fixture : GenerationAudit = {
    directory: "/fixture/generation-1",
    checkpoint_format: "moonrobo.native-tensor-checkpoint-pointer.v2",
    iteration: 1,
    identity: { "fixture": true },
    shared: digest_fixture(),
    archive_bytes: 3L,
    state_json_bytes: 2L,
    streamed_sidecar_bytes: 1L,
    streamed_sidecar_count: 1,
    planned_peak_host_bytes: 1073741824L,
    held_state_attestation_verified: Some(true),
  }
  for attestation in [Some(true), None] {
    let generation = {
      ..fixture,
      held_state_attestation_verified: attestation,
    }
    let report = verification_report(generation)
    guard report is Object(fields) else { fail("report must be an object") }
    assert_eq(
      fields.get("format"),
      Some("moonrobo.native-checkpoint-verification.v1"),
    )
    assert_eq(fields.get("verification_passed"), Some(true))
    assert_eq(fields.get("comparison_performed"), Some(false))
    assert_eq(fields.get("generation"), Some(Json(generation)))
    for
      key in [
        "left", "right", "identity_equal", "iteration_equal", "shared_state_equal",
      ] {
      assert_true(!fields.contains(key))
    }
  }
}
