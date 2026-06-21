///|
pub(all) struct SdkE1MotorState {
  motor_id : Int
  position : Double
  velocity : Double
  torque : Double
  error : Int
  temperature : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SdkE1ImuData {
  orientation : Array[Double]
  angular_velocity : Array[Double]
  linear_acceleration : Array[Double]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SdkE1JoyData {
  axes : Array[Double]
  buttons : Array[Int]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SdkE1Snapshot {
  frame_id : String
  captured_at_ms : Int64
  mode : Int
  telemetry_age_ms : Int
  joints : Array[SdkE1MotorState]
  imu : SdkE1ImuData?
  joy : SdkE1JoyData?
  errors : Array[String]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SdkE1AdapterIssue {
  code : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
fn issue(code : String, message : String) -> SdkE1AdapterIssue {
  { code, message }
}

///|
pub fn mode_text(mode : Int) -> String {
  match mode {
    0 => "low"
    1 => "high"
    2 => "user"
    3 => "default"
    _ => "unknown-\{mode}"
  }
}

///|
pub fn read_only_capabilities() -> Array[@core.CapabilityId] {
  ["observe.telemetry", "observe.joints", "observe.imu"]
}

///|
pub fn default_snapshot(
  frame_id : String,
  captured_at_ms : Int64,
  telemetry_age_ms? : Int = 0,
) -> SdkE1Snapshot {
  {
    frame_id,
    captured_at_ms,
    mode: 1,
    telemetry_age_ms,
    joints: [],
    imu: Some({
      orientation: [1.0, 0.0, 0.0, 0.0],
      angular_velocity: [0.0, 0.0, 0.0],
      linear_acceleration: [0.0, 0.0, 9.8],
    }),
    joy: Some({
      axes: [0.0, 0.0],
      buttons: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    }),
    errors: [],
  }
}

///|
pub fn default_joint_states(
  profile : @core.RobotProfile,
) -> Array[SdkE1MotorState] {
  profile.joints.map(fn(joint) {
    {
      motor_id: joint.index,
      position: joint.index.to_double() * 0.01,
      velocity: 0.0,
      torque: 0.0,
      error: 0,
      temperature: 0,
    }
  })
}

///|
pub fn validate_snapshot(
  profile : @core.RobotProfile,
  snapshot : SdkE1Snapshot,
) -> Result[Unit, SdkE1AdapterIssue] {
  if snapshot.joints.length() != profile.joints.length() {
    return Err(
      issue(
        "joint-count-mismatch", "SDK E1 snapshot joint count does not match RobotProfile",
      ),
    )
  }
  for joint in profile.joints {
    match snapshot.joints.get(joint.index) {
      None =>
        return Err(
          issue(
            "joint-index-missing",
            "SDK E1 snapshot is missing profile joint index \{joint.index}",
          ),
        )
      Some(state) =>
        if state.motor_id != joint.index {
          return Err(
            issue(
              "motor-id-mismatch", "SDK E1 motor id does not match profile joint index",
            ),
          )
        }
    }
  }
  Ok(())
}

///|
fn joint_error(error : Int) -> String? {
  if error == 0 {
    None
  } else {
    Some("sdk-error-\{error}")
  }
}

///|
fn operator_input(joy : SdkE1JoyData?) -> Map[String, String] {
  match joy {
    None => { "source": "sdk-e1" }
    Some(joy) =>
      {
        "source": "sdk-e1",
        "axes": joy.axes.to_json().stringify(),
        "buttons": joy.buttons.to_json().stringify(),
      }
  }
}

///|
pub fn telemetry_frame(
  profile : @core.RobotProfile,
  snapshot : SdkE1Snapshot,
) -> Result[@core.TelemetryFrame, SdkE1AdapterIssue] {
  match validate_snapshot(profile, snapshot) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let joints : Array[@core.JointTelemetry] = profile.joints.map(fn(joint) {
    let state = snapshot.joints[joint.index]
    {
      name: joint.name,
      index: joint.index,
      position: state.position,
      velocity: state.velocity,
      torque: state.torque,
      error: joint_error(state.error),
    }
  })
  let imu : @core.ImuTelemetry? = match snapshot.imu {
    None => None
    Some(imu) =>
      Some({
        orientation: imu.orientation,
        angular_velocity: imu.angular_velocity,
        linear_acceleration: imu.linear_acceleration,
      })
  }
  Ok({
    frame_id: snapshot.frame_id,
    robot_id: profile.id,
    bridge_id: profile.bridge.id,
    captured_at_ms: snapshot.captured_at_ms,
    mode: mode_text(snapshot.mode),
    joints,
    imu,
    operator_input: operator_input(snapshot.joy),
    errors: snapshot.errors,
  })
}

///|
pub fn health(
  profile : @core.RobotProfile,
  snapshot : SdkE1Snapshot,
) -> @core.BridgeHealth {
  @core.bridge_ok(
    profile.bridge.id,
    profile.id,
    mode=mode_text(snapshot.mode),
    last_telemetry_age_ms=snapshot.telemetry_age_ms,
  )
}

///|
pub fn telemetry_response(
  request_id : String,
  profile : @core.RobotProfile,
  snapshot : SdkE1Snapshot,
) -> Result[@bridge_protocol.BridgeResponse, SdkE1AdapterIssue] {
  let request = @bridge_protocol.telemetry_request(
    request_id,
    profile,
    snapshot.captured_at_ms,
  )
  let frame = match telemetry_frame(profile, snapshot) {
    Ok(frame) => frame
    Err(error) => return Err(error)
  }
  Ok(@bridge_protocol.telemetry_response(request, frame))
}

///|
pub fn health_response(
  request_id : String,
  profile : @core.RobotProfile,
  snapshot : SdkE1Snapshot,
) -> @bridge_protocol.BridgeResponse {
  let request = @bridge_protocol.health_request(
    request_id,
    profile,
    snapshot.captured_at_ms,
  )
  @bridge_protocol.health_response(request, health(profile, snapshot))
}

///|
pub fn snapshot_json(snapshot : SdkE1Snapshot, indent? : Int = 2) -> String {
  snapshot.to_json().stringify(indent~)
}

///|
pub fn parse_snapshot(
  text : String,
) -> Result[SdkE1Snapshot, SdkE1AdapterIssue] {
  let json = @json.parse(text) catch {
    _ =>
      return Err(
        issue("parse-snapshot", "failed to parse SDK E1 snapshot JSON"),
      )
  }
  let snapshot : SdkE1Snapshot = @json.from_json(json) catch {
    _ =>
      return Err(issue("decode-snapshot", "failed to decode SDK E1 snapshot"))
  }
  Ok(snapshot)
}
