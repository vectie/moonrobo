///|
test "R37 retained catalogue and inspections preserve exact store bytes and native frozen outcomes" {
  let request = q12_request("r37-accepted", "q11-a")
  let root = q12_root("r37-catalogue", request)
  let _ = @runtime.import_digital_trial(root, request)
  let _ = @runtime.import_digital_trial(
    root,
    q12_request("r37-rejected", "q11-b"),
  )
  let dir = @runtime.moonrobo_proof_sessions_dir(root) +
    "/digital-trials/r37-accepted"
  let before = @fsx.read_file_to_string(dir + "/import.json")
  let head = @fsx.read_file_to_string(dir + "/head.json")
  let response = @host_api.route(root, "GET", "/api/moonrobo/digital-trials")
  assert_eq(response.status, 200)
  assert_true(
    @json.parse(response.body)
    is {
      "state": "available",
      "entries": [
        { "digital_result": "accepted", "selectable": True, .. },
        { "digital_result": "rejected", "selectable": True, .. },
      ],
      "limit": Number(32, ..),
      "truncated": False,
      ..
    },
  )
  let view = q12_view(
    @host_api.route(root, "GET", "/api/moonrobo/digital-trials/r37-accepted"),
  )
  assert_true(
    view.record.binding.frozen_evidence
    is { "baseline_verified": True, "metrics": Array(metrics), .. } &&
    metrics.length() == 8,
  )
  assert_eq(view.record.binding.digital_result, "accepted")
  @fsx.write_string_to_file(root + "/robot.json", before)
  let changed = q12_view(
    @host_api.route(root, "GET", "/api/moonrobo/digital-trials/r37-accepted"),
  )
  assert_eq(changed.binding_state, "blocked")
  assert_eq(changed.record.binding, view.record.binding)
  assert_eq(@fsx.read_file_to_string(dir + "/import.json"), before)
  assert_eq(@fsx.read_file_to_string(dir + "/head.json"), head)
  let _ = @runtime.append_digital_trial_event(
    root,
    q12_event("r37-accepted", 0, "lost-ack", ""),
  )
  let lost = q12_view(
    @host_api.route(root, "GET", "/api/moonrobo/digital-trials/r37-accepted"),
  )
  assert_eq(lost.acknowledgement_state, "unknown")
  assert_eq(lost.record.binding.digital_result, "accepted")
  assert_eq(lost.record.events.length(), 1)
}

///|
test "R37 invalid missing truncated retained catalogue is explicit and never repaired" {
  let request = q12_request("a-valid", "q11-a")
  let root = q12_root("r37-invalid", request)
  let _ = @runtime.import_digital_trial(root, request)
  let base = @runtime.moonrobo_proof_sessions_dir(root) + "/digital-trials"
  ensure_dir(base + "/b-missing")
  ensure_dir(base + "/c-invalid")
  @fsx.write_string_to_file(base + "/c-invalid/import.json", "not json")
  @fsx.write_string_to_file(base + "/c-invalid/head.json", "{}")
  ensure_dir(base + "/d-truncated")
  @fsx.write_string_to_file(base + "/d-truncated/import.json", "preserve")
  @fsx.write_string_to_file(base + "/d-truncated/head.json", "preserve")
  for i in 1..<=129 {
    @fsx.write_string_to_file(
      base + "/d-truncated/event-" + i.to_string() + ".json",
      "preserve",
    )
  }
  let response = @host_api.route(root, "GET", "/api/moonrobo/digital-trials")
  assert_true(
    @json.parse(response.body)
    is {
      "entries": [
        { "state": "verified", .. },
        { "state": "missing-evidence", "selectable": False, .. },
        { "state": "invalid-evidence", "selectable": False, .. },
        { "state": "truncated-history", "selectable": False, .. },
      ],
      ..
    },
  )
  assert_eq(
    @fsx.read_file_to_string(base + "/c-invalid/import.json"),
    "not json",
  )
  assert_false(@fsx.path_exists(base + "/b-missing/import.json"))
}

///|
test "R37 bounded catalogue reports overflow without selecting an uninspected trial" {
  let root = q12_root("r37-count", q12_request("seed", "q11-a"))
  let _ = @runtime.import_digital_trial(root, q12_request("a-seed", "q11-a"))
  let base = @runtime.moonrobo_proof_sessions_dir(root) + "/digital-trials"
  for i in 0..<35 {
    ensure_dir(base + "/z-missing-" + i.to_string())
  }
  let response = @host_api.route(root, "GET", "/api/moonrobo/digital-trials")
  assert_true(
    @json.parse(response.body)
    is {
      "state": "truncated",
      "truncated": True,
      "entries": Array(entries),
      ..
    } &&
    entries.length() == 32,
  )
  assert_false(@fsx.path_exists(base + "/z-missing-34/import.json"))
}
