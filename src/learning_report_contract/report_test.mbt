///|
test "pooled report preserves per-case denominators and sorted identities" {
  let rows : Array[Json] = [
    {
      "case_id": "b",
      "failed": false,
      "simulated_seconds": 6.0,
      "joint_rmse_rad": 0.3,
    },
    {
      "case_id": "a",
      "failed": true,
      "simulated_seconds": 2.0,
      "joint_rmse_rad": 0.1,
    },
    {
      "case_id": "b",
      "failed": false,
      "simulated_seconds": 4.0,
      "joint_rmse_rad": 0.2,
    },
  ]
  guard @learning_report_contract.pooled(rows, { "mode": "fixed" })
    is Object(result) else {
    fail("object required")
  }
  assert_eq(result["trials"], (3 : Json))
  assert_eq(result["falls"], (1 : Json))
  assert_eq(result["mean_survival_s"], (4.0 : Json))
  guard result["cases"] is Array(cases) &&
    cases[0] is Object(first) &&
    cases[1] is Object(second) else {
    fail("case summaries required")
  }
  assert_eq(first["case_id"], ("a" : Json))
  assert_eq(first["trials"], (1 : Json))
  assert_eq(second["trials"], (2 : Json))
  assert_eq(second["mean_survival_s"], (5.0 : Json))
  assert_eq(result["mode"], ("fixed" : Json))
}

///|
test "pooled report rejects empty or missing case identities" {
  let empty = @learning_report_contract.pooled([], {}) catch {
    _ => Json::null()
  }
  assert_eq(empty, Json::null())
  let missing = @learning_report_contract.pooled(
    [{ "failed": false, "simulated_seconds": 1.0, "joint_rmse_rad": 0.0 }],
    {},
  ) catch {
    _ => Json::null()
  }
  assert_eq(missing, Json::null())
}
