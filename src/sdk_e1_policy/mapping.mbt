///|
/// q_model = direction * (q_sdk - zero). Both positions are radians; direction
/// is +1/-1. The SDK name/ID, zero and gains require physical qualification.
pub(all) struct Axis {
  actor_joint : String
  sdk_joint : String
  motor_id : Int32
  direction : Double
  zero : Double
  kp : Double
  kd : Double
} derive(FromJson)

///|
pub extend Axis with @json.FromJson::{from_json}

///|
/// Explicit command for an SDK joint absent from the actor (for example, the
/// 24th joint of a 23-axis actor). This is not an inferred zero/hold/stop frame.
pub(all) struct FixedMotor {
  sdk_joint : String
  motor_id : Int32
  position : Double
  velocity : Double
  torque : Double
  kp : Double
  kd : Double
} derive(FromJson)

///|
pub extend FixedMotor with @json.FromJson::{from_json}

///|
pub(all) struct Calibration {
  format : String
  profile_id : String
  axes : Array[Axis]
  fixed : Array[FixedMotor]
} derive(FromJson)

///|
pub extend Calibration with @json.FromJson::{from_json}

///|
priv struct BoundAxis {
  actor_index : Int32
  slot : Int32
  calibration : Axis
}

///|
/// Pure conversion owner. Resolution is performed once by the caller-supplied
/// lookup, which may be a qualified Controller::joint_index or an offline map.
/// Construction performs no SDK initialization and does not publish commands.
pub struct Mapping {
  priv bundle : @actor.Bundle
  priv axes : Array[BoundAxis]
  priv expected_ids : FixedArray[Int32]
  priv fixed_commands : Array[(@low.MotorCommand, Int32)]
}

///|
fn finite(value : Double) -> Bool {
  value == value && value - value == 0.0
}

///|
fn gain(value : Double) -> Bool {
  finite(value) && value >= 0.0
}

///|
pub fn Mapping::profile_id(self : Self) -> String {
  self.bundle.profile_id()
}

///|
pub fn Mapping::new(
  bundle : @actor.Bundle,
  calibration : Calibration,
  resolve~ : (String) -> Int32 raise,
) -> Self raise {
  let count = bundle.joints().length()
  guard calibration.format == "moonrobo.e1-sdk-calibration.v1" &&
    calibration.profile_id == bundle.profile_id() &&
    calibration.axes.length() == count &&
    calibration.fixed.length() == 24 - count else {
    fail("SDK calibration does not cover the selected E1 actor profile")
  }
  let occupied = FixedArray::make(24, false)
  let expected_ids = FixedArray::make(24, -1)
  let controlled = FixedArray::make(count, false)
  let names : Array[String] = []
  fn bind(name : String, motor_id : Int32) -> Int32 raise {
    guard name != "" &&
      !names.contains(name) &&
      motor_id >= 0 &&
      motor_id <= 65535 else {
      fail("invalid motor ID or repeated calibrated SDK joint name")
    }
    let slot = resolve(name)
    guard slot >= 0 && slot < 24 && !occupied[slot] else {
      fail("SDK joint lookup is outside or duplicates the 24-slot frame")
    }
    occupied[slot] = true
    expected_ids[slot] = motor_id
    names.push(name)
    slot
  }
  let axes = calibration.axes.map(axis => {
    guard bundle.joints().search_by(name => name == axis.actor_joint)
      is Some(actor_index) &&
      !controlled[actor_index] &&
      (axis.direction == 1.0 || axis.direction == -1.0) &&
      finite(axis.zero) &&
      gain(axis.kp) &&
      gain(axis.kd) else {
      fail("invalid calibrated actor joint, direction, offset or gains")
    }
    controlled[actor_index] = true
    {
      actor_index,
      slot: bind(axis.sdk_joint, axis.motor_id),
      calibration: axis,
    }
  })
  let fixed_commands = calibration.fixed.map(motor => {
    guard [motor.position, motor.velocity, motor.torque].all(finite) &&
      gain(motor.kp) &&
      gain(motor.kd) else {
      fail("invalid explicit non-actor motor command")
    }
    let slot = bind(motor.sdk_joint, motor.motor_id)
    let command : @low.MotorCommand = {
      position: motor.position,
      velocity: motor.velocity,
      torque: motor.torque,
      kp: motor.kp,
      kd: motor.kd,
    }
    (command, slot)
  })
  { bundle, axes, expected_ids, fixed_commands, }
}

///|
/// Calibrated physical q/qd in actor-profile order. Sample age remains the
/// reference owner's responsibility; this does not interpret the SDK IMU.
pub fn Mapping::joint_state(
  self : Self,
  sample : @low.Sample,
) -> (Array[Double], Array[Double]) raise {
  let joints = Array::makei(24, slot => sample.joint(slot))
  self.joint_values(
    joints.map(j => j.motor_id)[:],
    joints.map(j => j.position)[:],
    joints.map(j => j.velocity)[:],
    joints.map(j => j.error)[:],
  )
}

///|
/// Same calibrated conversion for independently decoded status packets.
/// Caller owns packet continuity, source identity and receipt freshness.
pub fn Mapping::joint_values(
  self : Self,
  ids : ArrayView[Int32],
  positions : ArrayView[Double],
  velocities : ArrayView[Double],
  errors : ArrayView[Int32],
) -> (Array[Double], Array[Double]) raise {
  guard ids.length() == 24 &&
    positions.length() == 24 &&
    velocities.length() == 24 &&
    errors.length() == 24 &&
    positions.all(finite) &&
    velocities.all(finite) else {
    fail("incomplete or nonfinite SDK joint arrays")
  }
  for slot in 0..<24 {
    guard ids[slot] == self.expected_ids[slot] && errors[slot] == 0 else {
      fail("SDK status motor identity or error differs from calibration")
    }
  }
  let q = Array::make(self.axes.length(), 0.0)
  let qd = Array::make(self.axes.length(), 0.0)
  for axis in self.axes {
    let calibration = axis.calibration
    q[axis.actor_index] = calibration.direction *
      (positions[axis.slot] - calibration.zero)
    qd[axis.actor_index] = calibration.direction * velocities[axis.slot]
  }
  guard q.all(finite) && qd.all(finite) else {
    fail("calibrated SDK joint state is not finite")
  }
  (q, qd)
}

///|
/// Previous-action features for the complete command after action adaptation.
/// Fixed non-actor records are deliberately absent from the 29-value embedding.
pub fn Mapping::actions_for_commands(
  self : Self,
  commands : ArrayView[@low.MotorCommand],
) -> Array[Double] raise {
  guard commands.length() == 24 && commands.all(m => finite(m.position)) else {
    fail("complete finite applied command frame required")
  }
  let positions = Array::make(self.axes.length(), 0.0)
  for axis in self.axes {
    positions[axis.actor_index] = axis.calibration.direction *
      (commands[axis.slot].position - axis.calibration.zero)
  }
  self.bundle.actions_for_setpoints(positions[:])
}

///|
/// Build all24 SDK-slot commands, with nominal actor positions converted by
/// explicit calibration. Controlled joints use position PD (zero target speed
/// and feedforward torque). Extra motors use their complete explicit commands.
/// Caller owns freshness, authority, limits, watchdog and actual publication.
pub fn Mapping::commands(
  self : Self,
  actions : ArrayView[Double],
) -> Array[@low.MotorCommand] raise {
  let positions = self.bundle.nominal_setpoints(actions)
  let result : Array[@low.MotorCommand] = Array::make(24, {
    position: 0.0,
    velocity: 0.0,
    torque: 0.0,
    kp: 0.0,
    kd: 0.0,
  })
  for axis in self.axes {
    let calibration = axis.calibration
    let position = calibration.zero +
      calibration.direction * positions[axis.actor_index]
    guard finite(position) else { fail("SDK setpoint conversion overflow") }
    result[axis.slot] = {
      position,
      velocity: 0.0,
      torque: 0.0,
      kp: calibration.kp,
      kd: calibration.kd,
    }
  }
  for (command, slot) in self.fixed_commands {
    result[slot] = command
  }
  result
}
