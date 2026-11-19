///|
/// The decoder establishes the schema and emits all 24 ordered SDK slots.
priv struct StatusLine {
  packet : @ankle.Packet
  motor_ids : Array[Int32]
} derive(FromJson)

///|
async fn read_status() -> @ankle.Packet {
  let input : &@io.Reader = @stdio.stdin
  guard input.read_until("\n") is Some(line) else {
    fail("end of packet stream")
  }
  let status : StatusLine = @json.from_json(@json.parse(line))
  let p = status.packet
  guard status.motor_ids.length() == 24 &&
    p.q.length() == 24 &&
    p.qd.length() == 24 &&
    p.error.length() == 24 else {
    fail("incomplete status line")
  }
  for i, id in status.motor_ids {
    guard i == id else { fail("SDK motor ID mismatch") }
  }
  p
}

///|
fn status_sample(p : @ankle.Packet) -> @elbow.Sample {
  {
    source_ns: p.source_ns,
    receipt_ms: p.arrival_ns / 1000000L,
    motors: Array::makei(24, i => {
      id: i,
      position: p.q[i],
      velocity: p.qd[i],
      error: p.error[i],
    }),
  }
}
