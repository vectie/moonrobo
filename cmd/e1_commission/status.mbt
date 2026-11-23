///|
/// The decoder establishes the schema and emits all 24 ordered SDK slots.
priv struct StatusLine {
  packet : @ankle.Packet
  motor_ids : Array[Int32]
} derive(FromJson)

///|
async fn read_status() -> (@ankle.Packet, Array[Double]?) {
  let input : &@io.Reader = @stdio.stdin
  guard input.read_until("\n") is Some(line) else {
    fail("end of packet stream")
  }
  let value = @json.parse(line)
  decode_status(
    value,
    position_only=@env.get_env_var("MOONROBO_E1_POSITION_HOLD_SHADOW")
      is Some(_) ||
      @env.get_env_var("MOONROBO_E1_POSITION_HOLD_TRIAL") is Some(_) ||
      @env.get_env_var("MOONROBO_E1_SUPPORTED_ELBOW_PROFILE") is Some(_),
  )
}

///|
fn decode_status(
  value : Json,
  position_only~ : Bool,
) -> (@ankle.Packet, Array[Double]?) raise {
  let status : StatusLine = @json.from_json(value)
  let reported_tau : Array[Double]? = if position_only {
    None
  } else {
    match value {
      { "packet": { "tau": tau, .. }, .. } => Some(@json.from_json(tau))
      _ => None
    }
  }
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
  (p, reported_tau)
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
