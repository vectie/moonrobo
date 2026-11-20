///|
priv struct Status {
  packet : @ankle.Packet
  motor_ids : Array[Int32]
  orientation : Array[Double]
  angular_velocity : Array[Double]
} derive(FromJson)

///|
async fn read_status() -> Status {
  let input : &@io.Reader = @stdio.stdin
  guard input.read_until("\n") is Some(line) else {
    fail("end of actor telemetry")
  }
  let s : Status = @json.from_json(@json.parse(line))
  guard s.motor_ids == Array::makei(24, i => i) &&
    s.orientation.length() == 4 &&
    s.angular_velocity.length() == 3 else {
    fail("actor status schema incomplete")
  }
  s
}

///|
async fn emit(value : Json) -> Unit {
  let output : &@io.Writer = @stdio.stdout
  output.write(value.stringify() + "\n")
}

///|
async fn diagnose(text : String) -> Unit {
  let output : &@io.Writer = @stdio.stderr
  output.write(text + "\n")
}

///|
async fn timed_status(timeout : Int32, context : String) -> Status {
  @async.with_timeout(timeout, read_status) catch {
    error => fail(context + ": " + error.to_string())
  }
}

///|
fn hold_from(s : Status) -> Array[@low.MotorCommand] raise {
  let sample : @elbow.Sample = {
    source_ns: s.packet.source_ns,
    receipt_ms: s.packet.arrival_ns / 1000000L,
    motors: Array::makei(24, i => {
      id: s.motor_ids[i],
      position: s.packet.q[i],
      velocity: s.packet.qd[i],
      error: s.packet.error[i],
    }),
  }
  sample.stand_candidate()
}
