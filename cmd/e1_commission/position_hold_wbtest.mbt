///|
fn raw_status(tau : Json) -> Json {
  {
    "motor_ids": Json(Array::makei(24, i => i)),
    "packet": {
      "seq": 1,
      "source_ns": "1000000000",
      "arrival_ns": "1000000000",
      "q": Json(Array::make(24, -0.1)),
      "qd": Json(Array::make(24, 0.0)),
      "error": Json(Array::make(24, 0)),
      "tau": tau,
    },
  }
}

///|
test "position hold status ignores optional torque while preserving all 24 raw positions" {
  for
    tau in [
      Json::null(),
      Json(Array::make(24, 0.0)),
      Json(Array::make(24, 90.0)),
      Json("unavailable"),
    ] {
    let (packet, reported) = decode_status(raw_status(tau), position_only=true)
    assert_eq(packet.q.length(), 24)
    assert_eq(packet.q[19], -0.1)
    assert_true(reported is None)
  }
  let (_, reported) = decode_status(
    raw_status(Json(Array::make(24, 1.0))),
    position_only=false,
  )
  assert_true(
    reported is Some(values) && values.length() == 24 && values[7] == 1.0,
  )
}
