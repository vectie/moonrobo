///|
test "packet stream requires complete ordered SDK motor IDs" {
  let ids = Array::makei(24, i => i)
  let q = Array::make(24, 0.0)
  let packet : Json = {
    "seq": 1,
    "source_ns": "1000",
    "arrival_ns": "2000",
    "q": Json(q),
    "qd": Json(q),
    "error": Json(Array::make(24, 0)),
  }
  let line = (ids : Array[Int32]) => {
    let value : Json = { "packet": packet, "motor_ids": Json(ids) }
    value.stringify()
  }
  assert_eq(parse_status_line(line(ids)).seq, 1)
  ids[23] = 22
  let rejected = try {
    ignore(parse_status_line(line(ids)))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}
