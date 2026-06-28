///|
pub(all) struct MoonmoonNoetixMotorTargetStep {
  joint_id : String
  parent_link : String
  child_link : String
  side : String
  field : String
  before_position_rad : Double
  target_position_rad : Double
  target_velocity_rad_s : Double
  bounded_velocity_rad_s : Double
  angle_delta_rad : Double
  commanded_torque_nm : Double
  work_j : Double
  min_position_rad : Double
  max_position_rad : Double
  max_velocity_rad_s : Double
  max_torque_nm : Double
  stiffness_nm_per_rad : Double
  damping_nm_s_per_rad : Double
  position_within_limits : Bool
  velocity_within_limits : Bool
  torque_saturated : Bool
  status : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonmoonNoetixMotorFrameSample {
  frame_index : Int
  time_s : Double
  dt_s : Double
  phase_start : Double
  phase_end : Double
  phase_label : String
  support_foot : String
  joint_count : Int
  driven_joint_count : Int
  review_count : Int
  max_abs_angle_delta_rad : Double
  max_abs_velocity_rad_s : Double
  max_abs_commanded_torque_nm : Double
  total_absolute_work_j : Double
  steps : Array[MoonmoonNoetixMotorTargetStep]
  status : String
} derive(Debug, Eq, ToJson, FromJson)

///|
priv struct MoonmoonNoetixMotorSpec {
  joint_id : String
  parent_link : String
  child_link : String
  side : String
  field : String
  min_position_rad : Double
  max_position_rad : Double
  max_velocity_rad_s : Double
  max_torque_nm : Double
  stiffness_nm_per_rad : Double
  damping_nm_s_per_rad : Double
}

///|
fn noetix_motor_spec(
  joint_id : String,
  parent_link : String,
  child_link : String,
  side : String,
  field : String,
  min_position_rad : Double,
  max_position_rad : Double,
  max_velocity_rad_s : Double,
  max_torque_nm : Double,
  stiffness_nm_per_rad : Double,
  damping_nm_s_per_rad : Double,
) -> MoonmoonNoetixMotorSpec {
  {
    joint_id,
    parent_link,
    child_link,
    side,
    field,
    min_position_rad,
    max_position_rad,
    max_velocity_rad_s,
    max_torque_nm,
    stiffness_nm_per_rad,
    damping_nm_s_per_rad,
  }
}

///|
fn noetix_abs(value : Double) -> Double {
  if value < 0.0 {
    0.0 - value
  } else {
    value
  }
}

///|
fn noetix_max(a : Double, b : Double) -> Double {
  if a > b {
    a
  } else {
    b
  }
}

///|
fn noetix_e1_moonmoon_motor_specs() -> Array[MoonmoonNoetixMotorSpec] {
  [
    noetix_motor_spec(
      "leg_l1_joint", "base_link", "left_leg_1", "left", "hip", -1.2, 1.2, 3.0, 90.0,
      18.0, 0.8,
    ),
    noetix_motor_spec(
      "leg_l4_joint", "left_leg_3", "left_leg_4", "left", "knee", -1.8, 1.8, 3.0,
      100.0, 18.0, 0.8,
    ),
    noetix_motor_spec(
      "leg_l6_joint", "left_leg_5", "left_foot", "left", "ankle", -0.8, 0.8, 3.0,
      80.0, 14.0, 0.6,
    ),
    noetix_motor_spec(
      "leg_r1_joint", "base_link", "right_leg_1", "right", "hip", -1.2, 1.2, 3.0,
      90.0, 18.0, 0.8,
    ),
    noetix_motor_spec(
      "leg_r4_joint", "right_leg_3", "right_leg_4", "right", "knee", -1.8, 1.8, 3.0,
      100.0, 18.0, 0.8,
    ),
    noetix_motor_spec(
      "leg_r6_joint", "right_leg_5", "right_foot", "right", "ankle", -0.8, 0.8, 3.0,
      80.0, 14.0, 0.6,
    ),
    noetix_motor_spec(
      "arm_l1_joint", "chest_link", "left_arm_1", "left", "shoulder", -1.8, 1.8,
      3.0, 45.0, 8.0, 0.4,
    ),
    noetix_motor_spec(
      "arm_l4_joint", "left_arm_3", "left_arm_4", "left", "elbow", -1.6, 1.6, 3.0,
      30.0, 8.0, 0.4,
    ),
    noetix_motor_spec(
      "arm_r1_joint", "chest_link", "right_arm_1", "right", "shoulder", -1.8, 1.8,
      3.0, 45.0, 8.0, 0.4,
    ),
    noetix_motor_spec(
      "arm_r4_joint", "right_arm_3", "right_arm_4", "right", "elbow", -1.6, 1.6,
      3.0, 30.0, 8.0, 0.4,
    ),
  ]
}

///|
fn noetix_joint_position(
  sample : MoonmoonNoetixAuthoredJointSample,
  side : String,
  field : String,
) -> Double {
  if side == "left" {
    if field == "hip" {
      sample.left_hip_rad
    } else if field == "knee" {
      sample.left_knee_rad
    } else if field == "ankle" {
      sample.left_ankle_rad
    } else if field == "shoulder" {
      sample.left_shoulder_rad
    } else {
      sample.left_elbow_rad
    }
  } else if field == "hip" {
    sample.right_hip_rad
  } else if field == "knee" {
    sample.right_knee_rad
  } else if field == "ankle" {
    sample.right_ankle_rad
  } else if field == "shoulder" {
    sample.right_shoulder_rad
  } else {
    sample.right_elbow_rad
  }
}

///|
fn noetix_motor_step(
  spec : MoonmoonNoetixMotorSpec,
  before : MoonmoonNoetixAuthoredJointSample,
  after : MoonmoonNoetixAuthoredJointSample,
  dt_s : Double,
) -> MoonmoonNoetixMotorTargetStep {
  let before_position = noetix_joint_position(before, spec.side, spec.field)
  let target_position = noetix_joint_position(after, spec.side, spec.field)
  let angle_delta = target_position - before_position
  let target_velocity = if dt_s > 0.0 { angle_delta / dt_s } else { 0.0 }
  let bounded_velocity = clamp(
    target_velocity,
    0.0 - spec.max_velocity_rad_s,
    spec.max_velocity_rad_s,
  )
  let raw_torque = spec.stiffness_nm_per_rad * angle_delta +
    spec.damping_nm_s_per_rad * bounded_velocity
  let commanded_torque = clamp(
    raw_torque,
    0.0 - spec.max_torque_nm,
    spec.max_torque_nm,
  )
  let position_within_limits = target_position >= spec.min_position_rad &&
    target_position <= spec.max_position_rad
  let velocity_within_limits = noetix_abs(target_velocity) <=
    spec.max_velocity_rad_s + 0.000001
  let torque_saturated = noetix_abs(raw_torque - commanded_torque) > 0.000001
  let status = if !position_within_limits || !velocity_within_limits {
    "joint-limit-review"
  } else if torque_saturated {
    "joint-torque-review"
  } else {
    "joint-commanded"
  }
  {
    joint_id: spec.joint_id,
    parent_link: spec.parent_link,
    child_link: spec.child_link,
    side: spec.side,
    field: spec.field,
    before_position_rad: before_position,
    target_position_rad: target_position,
    target_velocity_rad_s: target_velocity,
    bounded_velocity_rad_s: bounded_velocity,
    angle_delta_rad: angle_delta,
    commanded_torque_nm: commanded_torque,
    work_j: commanded_torque * angle_delta,
    min_position_rad: spec.min_position_rad,
    max_position_rad: spec.max_position_rad,
    max_velocity_rad_s: spec.max_velocity_rad_s,
    max_torque_nm: spec.max_torque_nm,
    stiffness_nm_per_rad: spec.stiffness_nm_per_rad,
    damping_nm_s_per_rad: spec.damping_nm_s_per_rad,
    position_within_limits,
    velocity_within_limits,
    torque_saturated,
    status,
  }
}

///|
fn noetix_phase_label(phase : Double) -> String {
  if phase < 0.5 {
    "left-stance-right-swing"
  } else {
    "right-stance-left-swing"
  }
}

///|
fn noetix_support_foot(phase : Double) -> String {
  if phase < 0.5 {
    "left"
  } else {
    "right"
  }
}

///|
fn noetix_motor_frame(
  frame_index : Int,
  before : MoonmoonNoetixAuthoredJointSample,
  after : MoonmoonNoetixAuthoredJointSample,
  dt_s : Double,
  cycle_seconds : Double,
) -> MoonmoonNoetixMotorFrameSample {
  let steps : Array[MoonmoonNoetixMotorTargetStep] = []
  for spec in noetix_e1_moonmoon_motor_specs() {
    steps.push(noetix_motor_step(spec, before, after, dt_s))
  }
  let mut driven_joint_count = 0
  let mut review_count = 0
  let mut max_abs_angle_delta = 0.0
  let mut max_abs_velocity = 0.0
  let mut max_abs_torque = 0.0
  let mut total_absolute_work = 0.0
  for step in steps {
    if noetix_abs(step.angle_delta_rad) > 0.0001 {
      driven_joint_count += 1
    }
    if step.status != "joint-commanded" {
      review_count += 1
    }
    max_abs_angle_delta = noetix_max(
      max_abs_angle_delta,
      noetix_abs(step.angle_delta_rad),
    )
    max_abs_velocity = noetix_max(
      max_abs_velocity,
      noetix_abs(step.target_velocity_rad_s),
    )
    max_abs_torque = noetix_max(
      max_abs_torque,
      noetix_abs(step.commanded_torque_nm),
    )
    total_absolute_work += noetix_abs(step.work_j)
  }
  let status = if review_count > 0 {
    "world-heightfield-hinge-motor-review"
  } else if driven_joint_count > 0 {
    "world-heightfield-hinge-motor-driven"
  } else {
    "world-heightfield-hinge-motor-idle"
  }
  {
    frame_index,
    time_s: frame_index.to_double() * cycle_seconds / 24.0,
    dt_s,
    phase_start: before.phase,
    phase_end: after.phase,
    phase_label: noetix_phase_label(before.phase),
    support_foot: noetix_support_foot(before.phase),
    joint_count: steps.length(),
    driven_joint_count,
    review_count,
    max_abs_angle_delta_rad: max_abs_angle_delta,
    max_abs_velocity_rad_s: max_abs_velocity,
    max_abs_commanded_torque_nm: max_abs_torque,
    total_absolute_work_j: total_absolute_work,
    steps,
    status,
  }
}

///|
pub fn noetix_e1_moonmoon_authored_motor_frames() -> Array[
  MoonmoonNoetixMotorFrameSample,
] {
  let joint_samples = noetix_e1_moonmoon_authored_joint_samples()
  let sample_count = joint_samples.length()
  let cycle_seconds = 1.0 / 0.46
  let dt_s = cycle_seconds / sample_count.to_double()
  let frames : Array[MoonmoonNoetixMotorFrameSample] = []
  for index in 0..<sample_count {
    let next_index = if index + 1 == sample_count { 0 } else { index + 1 }
    frames.push(
      noetix_motor_frame(
        index,
        joint_samples[index],
        joint_samples[next_index],
        dt_s,
        cycle_seconds,
      ),
    )
  }
  frames
}
