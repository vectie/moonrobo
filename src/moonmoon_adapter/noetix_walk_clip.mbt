///|
pub(all) struct MoonmoonNoetixFootPhaseSpec {
  role : String
  phase_start : Double
  phase_end : Double
  support : Bool
  lock_window : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonmoonNoetixJointAnchor {
  joint_id : String
  side : String
  field : String
  phase : Double
  position_rad : Double
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonmoonNoetixJointCurveParam {
  name : String
  value : Double
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonmoonNoetixAuthoredJointSample {
  phase : Double
  left_hip_rad : Double
  left_knee_rad : Double
  left_ankle_rad : Double
  left_shoulder_rad : Double
  left_elbow_rad : Double
  right_hip_rad : Double
  right_knee_rad : Double
  right_ankle_rad : Double
  right_shoulder_rad : Double
  right_elbow_rad : Double
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonmoonNoetixWalkClipContract {
  clip_id : String
  source : String
  cycle_hz : Double
  root_speed_mps : Double
  stride_m : Double
  sample_count : Int
  foot_phase_sequence : Array[String]
  phase_labels : Array[String]
  foot_phase_specs : Array[MoonmoonNoetixFootPhaseSpec]
  required_joint_ids : Array[String]
  joint_anchors : Array[MoonmoonNoetixJointAnchor]
  joint_curve_params : Array[MoonmoonNoetixJointCurveParam]
  authored_joint_samples : Array[MoonmoonNoetixAuthoredJointSample]
  authored_motion_samples : Array[MoonmoonNoetixAuthoredMotionSample]
  blocker_count : Int
  blockers : Array[String]
  ready : Bool
  status : String
} derive(Debug, Eq, ToJson, FromJson)

///|
fn foot_phase_spec(
  role : String,
  phase_start : Double,
  phase_end : Double,
  support : Bool,
  lock_window : Bool,
) -> MoonmoonNoetixFootPhaseSpec {
  { role, phase_start, phase_end, support, lock_window }
}

///|
fn joint_anchor(
  joint_id : String,
  side : String,
  field : String,
  phase : Double,
  position_rad : Double,
) -> MoonmoonNoetixJointAnchor {
  { joint_id, side, field, phase, position_rad }
}

///|
fn joint_curve_param(
  name : String,
  value : Double,
) -> MoonmoonNoetixJointCurveParam {
  { name, value }
}

///|
priv struct NoetixLegJointAngles {
  hip_rad : Double
  knee_rad : Double
  ankle_rad : Double
}

///|
priv struct NoetixArmJointAngles {
  shoulder_rad : Double
  elbow_rad : Double
}

///|
fn cycle01(value : Double) -> Double {
  value - @math.floor(value)
}

///|
fn clamp(value : Double, min : Double, max : Double) -> Double {
  if value < min {
    min
  } else if value > max {
    max
  } else {
    value
  }
}

///|
fn smoothstep(value : Double) -> Double {
  let t = clamp(value, 0.0, 1.0)
  t * t * (3.0 - 2.0 * t)
}

///|
fn mix(a : Double, b : Double, t : Double) -> Double {
  a + (b - a) * t
}

///|
fn noetix_curve_param(name : String) -> Double {
  for param in noetix_e1_moonmoon_joint_curve_params() {
    if param.name == name {
      return param.value
    }
  }
  0.0
}

///|
pub fn noetix_e1_moonmoon_foot_phase_sequence() -> Array[String] {
  ["contact", "loading", "stance", "passing", "swing", "release"]
}

///|
pub fn noetix_e1_moonmoon_walk_phase_labels() -> Array[String] {
  ["left-stance-right-swing", "right-stance-left-swing"]
}

///|
pub fn noetix_e1_moonmoon_foot_phase_specs() -> Array[
  MoonmoonNoetixFootPhaseSpec,
] {
  [
    foot_phase_spec("contact", 0.0, 0.08, true, false),
    foot_phase_spec("loading", 0.08, 0.18, true, true),
    foot_phase_spec("stance", 0.18, 0.50, true, true),
    foot_phase_spec("passing", 0.50, 0.72, true, false),
    foot_phase_spec("swing", 0.72, 0.92, false, false),
    foot_phase_spec("release", 0.92, 1.0, true, false),
  ]
}

///|
pub fn noetix_e1_moonmoon_joint_anchors() -> Array[MoonmoonNoetixJointAnchor] {
  [
    joint_anchor("leg_l1_joint", "left", "hip", 0.0, -0.35),
    joint_anchor("leg_l1_joint", "left", "hip", 0.5, 0.28),
    joint_anchor("leg_l4_joint", "left", "knee", 0.0, -0.08),
    joint_anchor("leg_l4_joint", "left", "knee", 0.75, -0.82),
    joint_anchor("leg_l6_joint", "left", "ankle", 0.0, 0.12),
    joint_anchor("leg_l6_joint", "left", "ankle", 0.75, -0.28),
    joint_anchor("leg_r1_joint", "right", "hip", 0.0, 0.28),
    joint_anchor("leg_r1_joint", "right", "hip", 0.5, -0.35),
    joint_anchor("leg_r4_joint", "right", "knee", 0.25, -0.82),
    joint_anchor("leg_r4_joint", "right", "knee", 0.5, -0.08),
    joint_anchor("leg_r6_joint", "right", "ankle", 0.25, -0.28),
    joint_anchor("leg_r6_joint", "right", "ankle", 0.5, 0.12),
    joint_anchor("arm_l1_joint", "left", "shoulder", 0.0, -0.21),
    joint_anchor("arm_l4_joint", "left", "elbow", 0.0, 0.25),
    joint_anchor("arm_r1_joint", "right", "shoulder", 0.0, 0.21),
    joint_anchor("arm_r4_joint", "right", "elbow", 0.0, 0.25),
  ]
}

///|
pub fn noetix_e1_moonmoon_joint_curve_params() -> Array[
  MoonmoonNoetixJointCurveParam,
] {
  [
    joint_curve_param("hip_swing_start_rad", 0.28),
    joint_curve_param("hip_swing_end_rad", -0.36),
    joint_curve_param("hip_stance_start_rad", -0.35),
    joint_curve_param("hip_stance_end_rad", 0.28),
    joint_curve_param("stance_mid_progress", 0.42),
    joint_curve_param("stance_late_progress", 0.56),
    joint_curve_param("knee_base_rad", 0.08),
    joint_curve_param("knee_toe_off_lift_rad", 0.16),
    joint_curve_param("knee_swing_lift_rad", 0.74),
    joint_curve_param("knee_stance_lift_rad", 0.08),
    joint_curve_param("ankle_swing_wave_rad", -0.42),
    joint_curve_param("ankle_swing_start_rad", -0.08),
    joint_curve_param("ankle_swing_end_rad", 0.10),
    joint_curve_param("ankle_late_landing_rad", 0.04),
    joint_curve_param("ankle_stance_start_rad", 0.12),
    joint_curve_param("ankle_stance_end_rad", -0.08),
    joint_curve_param("arm_phase_lag", 0.44),
    joint_curve_param("shoulder_hip_scale", 0.76),
    joint_curve_param("shoulder_lag_wave_rad", 0.035),
    joint_curve_param("elbow_base_rad", 0.18),
    joint_curve_param("elbow_hip_scale", 0.24),
    joint_curve_param("elbow_lag_wave_rad", 0.045),
  ]
}

///|
fn noetix_e1_moonmoon_leg_angles(leg_phase : Double) -> NoetixLegJointAngles {
  let swing = leg_phase >= 0.5
  let u = if swing { (leg_phase - 0.5) * 2.0 } else { leg_phase * 2.0 }
  let e = smoothstep(u)
  if swing {
    let landing = if u > 0.45 {
      1.0 - smoothstep((u - 0.45) / 0.55)
    } else {
      1.0
    }
    let late_landing = smoothstep((u - 0.70) / 0.30)
    let toe_off_lift = smoothstep(u / 0.12) *
      (1.0 - smoothstep((u - 0.12) / 0.18))
    let swing_lift = @math.sin(u * @math.PI)
    let knee_lift = noetix_curve_param("knee_toe_off_lift_rad") * toe_off_lift +
      noetix_curve_param("knee_swing_lift_rad") * swing_lift * landing
    {
      hip_rad: mix(
        noetix_curve_param("hip_swing_start_rad"),
        noetix_curve_param("hip_swing_end_rad"),
        e,
      ),
      knee_rad: 0.0 - (noetix_curve_param("knee_base_rad") + knee_lift),
      ankle_rad: noetix_curve_param("ankle_swing_wave_rad") *
      @math.sin(u * @math.PI) +
      mix(
        noetix_curve_param("ankle_swing_start_rad"),
        noetix_curve_param("ankle_swing_end_rad"),
        e,
      ) +
      noetix_curve_param("ankle_late_landing_rad") * late_landing,
    }
  } else {
    let stance_progress = if u < 0.48 {
      mix(0.0, noetix_curve_param("stance_mid_progress"), smoothstep(u / 0.48))
    } else if u < 0.74 {
      mix(
        noetix_curve_param("stance_mid_progress"),
        noetix_curve_param("stance_late_progress"),
        smoothstep((u - 0.48) / 0.26),
      )
    } else {
      mix(
        noetix_curve_param("stance_late_progress"),
        1.0,
        smoothstep((u - 0.74) / 0.26),
      )
    }
    {
      hip_rad: mix(
        noetix_curve_param("hip_stance_start_rad"),
        noetix_curve_param("hip_stance_end_rad"),
        stance_progress,
      ),
      knee_rad: 0.0 -
      (
        noetix_curve_param("knee_base_rad") +
        noetix_curve_param("knee_stance_lift_rad") * @math.sin(u * @math.PI)
      ),
      ankle_rad: mix(
        noetix_curve_param("ankle_stance_start_rad"),
        noetix_curve_param("ankle_stance_end_rad"),
        stance_progress,
      ),
    }
  }
}

///|
fn noetix_e1_moonmoon_arm_angles(leg_phase : Double) -> NoetixArmJointAngles {
  let lagged_opposite_phase = cycle01(
    leg_phase + noetix_curve_param("arm_phase_lag"),
  )
  let leg = noetix_e1_moonmoon_leg_angles(lagged_opposite_phase)
  let lag_wave = @math.sin(lagged_opposite_phase * @math.PI * 2.0)
  {
    shoulder_rad: 0.0 -
    leg.hip_rad * noetix_curve_param("shoulder_hip_scale") +
    lag_wave * noetix_curve_param("shoulder_lag_wave_rad"),
    elbow_rad: noetix_curve_param("elbow_base_rad") +
    clamp(0.0 - leg.hip_rad, 0.0, 999.0) * noetix_curve_param("elbow_hip_scale") +
    clamp(lag_wave, 0.0, 999.0) * noetix_curve_param("elbow_lag_wave_rad"),
  }
}

///|
pub fn noetix_e1_moonmoon_authored_joint_samples() -> Array[
  MoonmoonNoetixAuthoredJointSample,
] {
  let sample_count = 24
  let samples : Array[MoonmoonNoetixAuthoredJointSample] = []
  for index in 0..<sample_count {
    let phase = index.to_double() / sample_count.to_double()
    let left_phase = phase
    let right_phase = cycle01(phase + 0.5)
    let left_leg = noetix_e1_moonmoon_leg_angles(left_phase)
    let right_leg = noetix_e1_moonmoon_leg_angles(right_phase)
    let left_arm = noetix_e1_moonmoon_arm_angles(left_phase)
    let right_arm = noetix_e1_moonmoon_arm_angles(right_phase)
    samples.push({
      phase,
      left_hip_rad: left_leg.hip_rad,
      left_knee_rad: left_leg.knee_rad,
      left_ankle_rad: left_leg.ankle_rad,
      left_shoulder_rad: left_arm.shoulder_rad,
      left_elbow_rad: left_arm.elbow_rad,
      right_hip_rad: right_leg.hip_rad,
      right_knee_rad: right_leg.knee_rad,
      right_ankle_rad: right_leg.ankle_rad,
      right_shoulder_rad: right_arm.shoulder_rad,
      right_elbow_rad: right_arm.elbow_rad,
    })
  }
  samples
}

///|
fn noetix_walk_clip_blockers() -> Array[String] {
  let blockers : Array[String] = []
  let phase_specs = noetix_e1_moonmoon_foot_phase_specs()
  if noetix_e1_moonmoon_foot_phase_sequence().length() != phase_specs.length() {
    blockers.push("foot-phase-spec-count")
  }
  let anchors = noetix_e1_moonmoon_joint_anchors()
  for joint_id in noetix_e1_moonmoon_required_motion_joint_ids() {
    if !anchors.any(fn(anchor) { anchor.joint_id == joint_id }) {
      blockers.push("missing-joint-anchor:\{joint_id}")
    }
  }
  let params = noetix_e1_moonmoon_joint_curve_params()
  for
    required in [
      "hip_swing_start_rad", "hip_swing_end_rad", "hip_stance_start_rad", "hip_stance_end_rad",
      "knee_base_rad", "knee_swing_lift_rad", "ankle_stance_start_rad", "ankle_stance_end_rad",
      "arm_phase_lag", "shoulder_hip_scale", "elbow_base_rad",
    ] {
    if !params.any(fn(param) { param.name == required }) {
      blockers.push("missing-joint-curve-param:\{required}")
    }
  }
  let samples = noetix_e1_moonmoon_authored_joint_samples()
  if samples.length() != 24 {
    blockers.push("authored-joint-sample-count")
  }
  if samples.any(fn(sample) {
      sample.left_knee_rad > 0.0 || sample.right_knee_rad > 0.0
    }) {
    blockers.push("authored-knee-forward-bend-sign")
  }
  let motion_samples = noetix_e1_moonmoon_authored_motion_samples()
  if motion_samples.length() != 24 {
    blockers.push("authored-motion-sample-count")
  }
  if motion_samples.any(fn(sample) {
      sample.left_foot_x_m < 0.0 || sample.right_foot_x_m > 0.0
    }) {
    blockers.push("authored-foot-side-sign")
  }
  blockers
}

///|
pub fn noetix_e1_moonmoon_walk_clip_contract() -> MoonmoonNoetixWalkClipContract {
  let blockers = noetix_walk_clip_blockers()
  {
    clip_id: "noetix-e1-lab-01/endless-forward-walk",
    source: "vectie/moonrobo/src/moonmoon_adapter#noetix_e1_moonmoon_walk_clip_contract",
    cycle_hz: 0.46,
    root_speed_mps: 0.18,
    stride_m: 0.38,
    sample_count: 24,
    foot_phase_sequence: noetix_e1_moonmoon_foot_phase_sequence(),
    phase_labels: noetix_e1_moonmoon_walk_phase_labels(),
    foot_phase_specs: noetix_e1_moonmoon_foot_phase_specs(),
    required_joint_ids: noetix_e1_moonmoon_required_motion_joint_ids(),
    joint_anchors: noetix_e1_moonmoon_joint_anchors(),
    joint_curve_params: noetix_e1_moonmoon_joint_curve_params(),
    authored_joint_samples: noetix_e1_moonmoon_authored_joint_samples(),
    authored_motion_samples: noetix_e1_moonmoon_authored_motion_samples(),
    blocker_count: blockers.length(),
    blockers,
    ready: blockers.is_empty(),
    status: if blockers.is_empty() {
      "moonmoon-noetix-walk-clip-ready"
    } else {
      "moonmoon-noetix-walk-clip-blocked"
    },
  }
}
