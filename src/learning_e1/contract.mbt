///|
pub(all) struct E1AlignmentIssue {
  code : String
  detail : String
} derive(Debug, Eq)

///|
fn issue(code : String, detail : String) -> E1AlignmentIssue {
  { code, detail, }
}

///|
/// SDK motor order, not an inferred semantic mapping from the G1 joints.
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
fn finite(values : Array[Double]) -> Bool {
  values.all(fn(value) { !value.is_nan() && !value.is_inf() })
}

///|
fn require_vector(
  name : String,
  values : Array[Double],
  length : Int32,
) -> Result[Unit, E1AlignmentIssue] {
  if values.length() != length {
    Err(issue("dimension", "\{name} requires \{length} values"))
  } else if !finite(values) {
    Err(issue("non-finite", "\{name} contains a non-finite value"))
  } else {
    Ok(())
  }
}

///|
/// The timestamp check uses total frame age, not only SDK capture duration.
pub fn validate_snapshot(
  snapshot : @sdk_e1.SdkE1Snapshot,
  now_ms : Int64,
  max_age_ms : Int64,
) -> Result[Unit, E1AlignmentIssue] {
  if snapshot.joints.length() != 24 {
    return Err(issue("joint-count", "E1 requires 24 motor states"))
  }
  if max_age_ms <= 0 ||
    snapshot.captured_at_ms > now_ms ||
    now_ms - snapshot.captured_at_ms > max_age_ms {
    return Err(
      issue("stale-state", "E1 snapshot age exceeds the declared bound"),
    )
  }
  if snapshot.telemetry_age_ms < 0 ||
    snapshot.telemetry_age_ms.to_int64() > max_age_ms {
    return Err(
      issue("stale-capture", "E1 SDK capture duration exceeds the bound"),
    )
  }
  if !snapshot.errors.is_empty() {
    return Err(issue("snapshot-error", "E1 snapshot reports an SDK error"))
  }
  for index, state in snapshot.joints {
    if state.motor_id != index {
      return Err(issue("motor-order", "E1 motor IDs must equal SDK indices"))
    }
    if state.error != 0 {
      return Err(issue("motor-error", "E1 motor reports a fault"))
    }
    if !finite([state.position, state.velocity, state.torque]) {
      return Err(issue("non-finite", "E1 motor state is not finite"))
    }
  }
  match snapshot.imu {
    None => Err(issue("missing-imu", "E1 snapshot has no IMU"))
    Some(imu) => {
      match require_vector("IMU quaternion", imu.orientation, 4) {
        Err(err) => return Err(err)
        Ok(_) => ()
      }
      match require_vector("IMU angular velocity", imu.angular_velocity, 3) {
        Err(err) => return Err(err)
        Ok(_) => ()
      }
      require_vector("IMU linear acceleration", imu.linear_acceleration, 3)
    }
  }
}

///|
/// Caller-supplied calibrated vectors keep unknown E1 IMU frame and quaternion
/// conventions out of the policy contract. None of these values is invented.
pub(all) struct E1ObservationInput {
  default_q : Array[Double]
  reference_delta_q : Array[Double]
  previous_action : Array[Double]
  body_angular_velocity : Array[Double]
  gravity_body : Array[Double]
  reference_orientation_6d : Array[Double]?
  reference_displacement_body : Array[Double]?
} derive(Debug)

///|
/// E1 analogue of paper Table A.1: 78, 84 or 87 features for 24 joints.
/// Additional 6D/3D reference errors are explicit extensions, not paper input.
pub fn observation(
  snapshot : @sdk_e1.SdkE1Snapshot,
  input : E1ObservationInput,
  now_ms : Int64,
  max_age_ms : Int64,
) -> Result[Array[Double], E1AlignmentIssue] {
  match validate_snapshot(snapshot, now_ms, max_age_ms) {
    Err(err) => return Err(err)
    Ok(_) => ()
  }
  for
    entry in [
      ("default_q", input.default_q, 24),
      ("reference_delta_q", input.reference_delta_q, 24),
      ("previous_action", input.previous_action, 24),
      ("body_angular_velocity", input.body_angular_velocity, 3),
      ("gravity_body", input.gravity_body, 3),
    ] {
    let (name, values, length) = entry
    match require_vector(name, values, length) {
      Err(err) => return Err(err)
      Ok(_) => ()
    }
  }
  let relative_orientation = match input.reference_orientation_6d {
    None => []
    Some(values) => {
      match require_vector("reference_orientation_6d", values, 6) {
        Err(err) => return Err(err)
        Ok(_) => ()
      }
      values
    }
  }
  let relative_position = match input.reference_displacement_body {
    None => []
    Some(values) => {
      if relative_orientation.is_empty() {
        return Err(
          issue(
            "observation-mode", "root displacement requires relative orientation",
          ),
        )
      }
      match require_vector("reference_displacement_body", values, 3) {
        Err(err) => return Err(err)
        Ok(_) => ()
      }
      values
    }
  }
  let out : Array[Double] = []
  for index, state in snapshot.joints {
    out.push(
      state.position - input.default_q[index] - input.reference_delta_q[index],
    )
  }
  for state in snapshot.joints {
    out.push(state.velocity)
  }
  for value in input.body_angular_velocity {
    out.push(value)
  }
  for value in input.gravity_body {
    out.push(value)
  }
  for value in input.previous_action {
    out.push(value)
  }
  for value in relative_orientation {
    out.push(value)
  }
  for value in relative_position {
    out.push(value)
  }
  Ok(out)
}

///|
/// Paper-style default-pose scaled action. E1 scales and default pose must be
/// measured for the target robot; G1's values are intentionally not reused.
pub fn action_setpoints(
  action : Array[Double],
  default_q : Array[Double],
  scale : Array[Double],
  calibration : Array[Double],
) -> Result[Array[Double], E1AlignmentIssue] {
  for
    entry in [
      ("action", action),
      ("default_q", default_q),
      ("scale", scale),
      ("calibration", calibration),
    ] {
    let (name, values) = entry
    match require_vector(name, values, 24) {
      Err(err) => return Err(err)
      Ok(_) => ()
    }
  }
  let out : Array[Double] = []
  for index in 0..<24 {
    let target = default_q[index] +
      scale[index] * action[index] +
      calibration[index]
    if target.is_nan() || target.is_inf() {
      return Err(issue("non-finite", "E1 setpoint is not finite"))
    }
    out.push(target)
  }
  Ok(out)
}
