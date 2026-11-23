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

///|
// Admit the captured pose before any baseline proposal can reach the sink.
// A rejected first packet must never be ignored merely because no later packet
// has arrived yet. The same suspended guard is used for subsequent packets.
fn hold_detector(packet : @ankle.Packet) -> @ankle.Detector raise {
  let detector = @ankle.Detector::new(
    packet,
    confirm_isolated=true,
    suspended=true,
  )
  match detector.observe(packet) {
    Use => detector
    Stop(reason, slot) => fail(reason + " slot " + slot.to_string())
    Wait => fail("provisional telemetry cannot establish an actor hold")
  }
}

///|
fn assessed_hold(
  previous : @ankle.Detector,
  packet : @ankle.Packet,
  shadow : Bool,
  current_pose : @adapter.CurrentPoseProfile?,
) -> @ankle.Detector raise {
  if current_pose is Some(profile) {
    profile.validate_baseline(packet.q[:])
  }
  if shadow || current_pose is Some(_) {
    // A measured pose is not an encoder-zero calibration. Read-only proposals
    // keep the validated stationary/glitch history rather than applying nominal
    // mechanical travel limits directly to unqualified raw feedback.
    guard !previous.suspended && previous.good.seq == packet.seq else {
      fail("shadow hold requires the current stationary assessment")
    }
    previous.begin_hold(moving_right_elbow=current_pose is Some(_))
  } else {
    hold_detector(packet)
  }
}

///|
async fn current_pose_profile() -> @adapter.CurrentPoseProfile? {
  match @env.get_env_var("MOONROBO_E1_CURRENT_POSE_PROFILE") {
    None => None
    Some(path) => Some(@json.from_json(@fs.read_file(path).json()))
  }
}

///|
fn nominal_leg_range_discrepancies(packet : @ankle.Packet) -> Array[Int32] {
  Array::makei(24, i => i).filter(slot => {
    @elbow.leg_slot(slot) && !@elbow.leg_position_in_range(slot, packet.q[slot])
  })
}
