///|
test "R37 native projection makes absent unsupported and nonfinite metrics unavailable" {
  for
    value in [
      Json::null(),
      "12".to_json(),
      true.to_json(),
      (1.0 / 0.0).to_json(),
      (0.0 / 0.0).to_json(),
    ] {
    assert_true(
      digital_metric({ "distance_m": value }, "distance_m", "Distance", "m")
      is { "value": Null, "available": False, .. },
    )
  }
  assert_true(
    digital_metric({ "distance_m": 0 }, "distance_m", "Distance", "m")
    is { "value": Number(0, ..), "available": True, .. },
  )
  assert_true(
    digital_metric({}, "distance_m", "Distance", "m")
    is { "value": Null, "available": False, .. },
  )
}
