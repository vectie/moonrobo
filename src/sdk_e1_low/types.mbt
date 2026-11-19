///|
/// Raw SDK values, before calibrated robot-frame conversion.
pub(all) struct JointState {
  motor_id : Int32
  position : Double
  velocity : Double
  torque : Double
  error : Int32
  temperature : Int32
}

///|
/// Targets in SDK slot order. A frame contains all 24 slots. The transport adds
/// motor_id=slot, matching the SDK3.1 example, without mapping actor outputs.
pub(all) struct MotorCommand {
  position : Double
  velocity : Double
  torque : Double
  kp : Double
  kd : Double
}

///|
/// Reusable storage, invalidated by a failed capture. SDK callbacks do not
/// mutate this MoonBit object; capture copies a coherent private C++ snapshot.
pub struct Sample {
  priv values : FixedArray[Double]
  priv age : FixedArray[Int64]
  priv mut valid : Bool
}

///|
pub fn Sample::new() -> Self {
  {
    values: FixedArray::make(171, 0.0),
    age: FixedArray::make(1, -1L),
    valid: false,
  }
}

///|
fn Sample::require_valid(self : Self) -> Unit raise {
  guard self.valid else { fail("low-control sample has no successful capture") }
}

///|
pub fn Sample::joint(self : Self, index : Int32) -> JointState raise {
  self.require_valid()
  guard index >= 0 && index < 24 else {
    fail("SDK motor slot is outside 0..23")
  }
  let base = index * 6
  {
    motor_id: self.values[base].to_int(),
    position: self.values[base + 1],
    velocity: self.values[base + 2],
    torque: self.values[base + 3],
    error: self.values[base + 4].to_int(),
    temperature: self.values[base + 5].to_int(),
  }
}

///|
/// Receipt age measured during the last capture, not a live-updating clock.
/// The reference adapter retains its capture time when checking freshness.
pub fn Sample::age_ms(self : Self) -> Int64 raise {
  self.require_valid()
  self.age[0]
}

///|
pub fn Sample::mode(self : Self) -> Int32 raise {
  self.require_valid()
  self.values[170].to_int()
}

///|
fn Sample::vector(
  self : Self,
  offset : Int32,
  count : Int32,
) -> ReadOnlyArray[Double] raise {
  self.require_valid()
  ReadOnlyArray::makei(count, i => self.values[offset + i])
}

///|
/// Raw SDK quaternion order; no frame convention is inferred.
pub fn Sample::orientation(self : Self) -> ReadOnlyArray[Double] raise {
  self.vector(144, 4)
}

///|
pub fn Sample::angular_velocity(self : Self) -> ReadOnlyArray[Double] raise {
  self.vector(148, 3)
}

///|
pub fn Sample::linear_acceleration(self : Self) -> ReadOnlyArray[Double] raise {
  self.vector(151, 3)
}

///|
pub fn Sample::remote_axes(self : Self) -> ReadOnlyArray[Double] raise {
  self.vector(154, 2)
}

///|
pub fn Sample::remote_buttons(self : Self) -> ReadOnlyArray[Int32] raise {
  self.require_valid()
  ReadOnlyArray::makei(14, i => self.values[156 + i].to_int())
}
