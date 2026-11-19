///|
/// Python bridge fixture port. Live publishing is exclusively in native.mbt.
pub fn joint_names() -> Array[String] {
  [
    "arm_l1_joint", "arm_l2_joint", "arm_l3_joint", "arm_l4_joint", "arm_l5_joint",
    "leg_l1_joint", "leg_l2_joint", "leg_l3_joint", "leg_l4_joint", "leg_l5_joint",
    "leg_l6_joint", "arm_r1_joint", "arm_r2_joint", "arm_r3_joint", "arm_r4_joint",
    "arm_r5_joint", "leg_r1_joint", "leg_r2_joint", "leg_r3_joint", "leg_r4_joint",
    "leg_r5_joint", "leg_r6_joint", "waist_1_joint", "waist_2_joint",
  ]
}

///|
pub fn fixture_snapshot(
  frame_id : String,
  captured_at_ms : Int64,
) -> @sdk.SdkE1Snapshot {
  let value = @sdk.default_snapshot(frame_id, captured_at_ms)
  {
    ..value,
    joints: Array::makei(24, i => {
      motor_id: i,
      position: i.to_double() * 0.01,
      velocity: 0.0,
      torque: 0.0,
      error: 0,
      temperature: 0,
    }),
  }
}

///|
pub fn frame_id_for(
  base : String,
  sequence : Int32,
  repeat : Bool,
  single_shot : Bool,
) -> String {
  if repeat || single_shot {
    base
  } else {
    "\{base}-\{sequence}"
  }
}

///|
pub fn validate_snapshot_shape(snapshot : @sdk.SdkE1Snapshot) -> Array[String] {
  let errors : Array[String] = []
  if snapshot.joints.length() != 24 {
    errors.push("snapshot must contain 24 joints")
  }
  for i, joint in snapshot.joints {
    if joint.motor_id != i {
      errors.push("joint \{i} motor_id mismatch")
    }
  }
  match snapshot.imu {
    Some(imu) => {
      if imu.orientation.length() != 4 {
        errors.push("imu orientation must contain 4 values")
      }
      if imu.angular_velocity.length() != 3 {
        errors.push("imu angular_velocity must contain 3 values")
      }
      if imu.linear_acceleration.length() != 3 {
        errors.push("imu linear_acceleration must contain 3 values")
      }
    }
    None => {
      errors.push("imu orientation must contain 4 values")
      errors.push("imu angular_velocity must contain 3 values")
      errors.push("imu linear_acceleration must contain 3 values")
    }
  }
  match snapshot.joy {
    Some(joy) => {
      if joy.axes.length() != 2 {
        errors.push("joy axes must contain 2 values")
      }
      if joy.buttons.length() != 14 {
        errors.push("joy buttons must contain 14 values")
      }
    }
    None => {
      errors.push("joy axes must contain 2 values")
      errors.push("joy buttons must contain 14 values")
    }
  }
  errors
}

///|
pub fn fixture_command() -> @sdk.SdkE1HighControlCommand {
  {
    intent_id: "intent-self-check",
    capability: "control.high.walk",
    action: "WALK",
    action_code: 0,
    vertical: 0.1,
    horizontal: 0.0,
    duration_ms: 1000,
    data: 0,
  }
}

///|
pub fn validate_command(
  command : @sdk.SdkE1HighControlCommand,
) -> Array[String] {
  let errors : Array[String] = []
  if !["WALK", "RUN", "DEFAULT"].contains(command.action) {
    errors.push("action must be WALK, RUN, or DEFAULT")
  }
  if command.vertical.is_nan() || command.vertical.is_inf() {
    errors.push("vertical must be finite")
  }
  if command.horizontal.is_nan() || command.horizontal.is_inf() {
    errors.push("horizontal must be finite")
  }
  errors
}

///|
pub suberror BridgeError {
  Invalid(String)
}

///|
pub fn load_command(text : String) -> @sdk.SdkE1HighControlCommand raise {
  let command : @sdk.SdkE1HighControlCommand = @json.from_json(
    @json.parse(text),
  )
  let errors = validate_command(command)
  if !errors.is_empty() {
    raise Invalid(errors.join("; "))
  }
  command
}

///|
pub fn dry_run(command : @sdk.SdkE1HighControlCommand) -> Json {
  {
    "published": false,
    "dry_run": true,
    "intent_id": command.intent_id,
    "action": command.action,
    "vertical": command.vertical,
    "horizontal": command.horizontal,
    "data": command.data,
  }
}

///|
/// Watch mode seeds the initial signature so an existing command is not replayed.
pub(all) struct WatchState {
  mut signature : (Int64, Int64)?
} derive(Debug)

///|
pub fn WatchState::new(watch : Bool, existing : (Int64, Int64)?) -> WatchState {
  { signature: if watch { existing } else { None }, }
}

///|
pub fn WatchState::changed(self : WatchState, current : (Int64, Int64)) -> Bool {
  self.signature != Some(current)
}

///|
/// Acknowledge only after a successful publish; failed commands remain retryable.
pub fn WatchState::acknowledge(
  self : WatchState,
  current : (Int64, Int64),
) -> Unit {
  self.signature = Some(current)
}
