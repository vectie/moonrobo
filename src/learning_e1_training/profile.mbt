///|
/// Versioned simulation profile. The standard 23-axis model is derived from
/// the vendor 24-axis model by fixing waist roll at zero, not hardware evidence.
pub(all) struct Profile {
  format : String
  id : String
  joints : Array[String]
  default_q : Array[Double]
  stiffness : Array[Double]
  damping : Array[Double]
  effort : Array[Double]
  velocity : Array[Double]
  armature : Array[Double]
  scales : Array[Double]
  tracked : Array[String]
} derive(Debug, ToJson, FromJson)

///|
pub fn profile(joints~ : Int32 = 23) -> Profile raise {
  guard joints == 23 || joints == 24 else {
    fail("E1 profile requires 23 or 24 physical axes")
  }
  let names : Array[String] = []
  for side in ["l", "r"] {
    for
      name in [
        "hip_yaw", "hip_roll", "hip_pitch", "knee", "ankle_pitch", "ankle_roll",
      ] {
      names.push(side + "_leg_" + name + "_joint")
    }
  }
  names.push("waist_yaw_joint")
  if joints == 24 {
    names.push("waist_roll_joint")
  }
  for side in ["l", "r"] {
    for
      name in [
        "shoulder_pitch", "shoulder_roll", "shoulder_yaw", "elbow_pitch", "elbow_yaw",
      ] {
      names.push(side + "_arm_" + name + "_joint")
    }
  }
  let q : Array[Double] = []
  let kp : Array[Double] = []
  let kd : Array[Double] = []
  let effort : Array[Double] = []
  let velocity : Array[Double] = []
  let armature : Array[Double] = []
  let frequency = 4.0 * 2.0 * @math.PI
  for name in names {
    let (inertia, force, speed, gain, damping_gain) = if name.contains(
        "hip_yaw",
      ) ||
      name.contains("hip_roll") {
      (0.04752756, 80.0, 10.0, 2.0, 2.0)
    } else if name.contains("hip_pitch") || name.contains("knee") {
      (0.068575968, 100.0, 14.0, 2.0, 1.45)
    } else if name.contains("ankle") {
      (0.033048, 70.0, 10.0, 1.05, 1.05)
    } else if name.contains("waist") {
      (0.033048, 60.0, 12.0, 2.0, 2.0)
    } else if name.contains("elbow") {
      (0.032, 20.0, 10.0, 1.2, 1.2)
    } else {
      (0.032, 20.0, 10.0, 2.0, 2.0)
    }
    q.push(
      if name.contains("hip_pitch") {
        -0.1495
      } else if name.contains("knee") {
        0.3215
      } else if name.contains("ankle_pitch") {
        -0.172
      } else if name == "l_arm_shoulder_roll_joint" {
        0.2618
      } else if name == "r_arm_shoulder_roll_joint" {
        -0.2618
      } else {
        0.0
      },
    )
    kp.push(inertia * frequency * frequency * gain)
    kd.push(2.0 * inertia * frequency * damping_gain)
    effort.push(force)
    velocity.push(speed)
    armature.push(inertia)
  }
  {
    format: "moonrobo.e1-embedded-profile.v1",
    id: "noetix-e1-\{joints}-lab-v1",
    joints: names,
    default_q: q,
    stiffness: kp,
    damping: kd,
    effort,
    velocity,
    armature,
    scales: Array::makei(joints, i => 0.25 * effort[i] / kp[i]),
    tracked: [
      "base_link", "l_leg_hip_roll_link", "l_leg_knee_link", "l_leg_ankle_roll_link",
      "r_leg_hip_roll_link", "r_leg_knee_link", "r_leg_ankle_roll_link", "waist_roll_link",
      "l_arm_shoulder_roll_link", "l_arm_elbow_pitch_link", "l_arm_elbow_yaw_link",
      "r_arm_shoulder_roll_link", "r_arm_elbow_pitch_link", "r_arm_elbow_yaw_link",
    ],
  }
}

///|
pub fn Profile::embed(
  self : Profile,
  values : Array[Double],
) -> Array[Double] raise {
  guard values.length() == self.joints.length() && values.all(@numeric.finite) else {
    fail("E1 vector dimensions or finite values differ")
  }
  Array::makei(29, i => values.get(i).unwrap_or(0.0))
}

///|
pub fn Profile::project(
  self : Profile,
  values : Array[Double],
) -> Array[Double] raise {
  guard values.length() == 29 && values.all(@numeric.finite) else {
    fail("invalid embedded E1 action")
  }
  Array::makei(29, i => if i < self.joints.length() { values[i] } else { 0.0 })
}

///|
pub fn Profile::contract(self : Profile) -> Json {
  self.sensor_contract(legacy=false)
}

///|
fn Profile::sensor_contract(self : Profile, legacy~ : Bool) -> Json {
  {
    "profile": Json(self),
    "internal_actions": 29,
    "physical_actions": Json(self.joints.length()),
    "observation_mode": "smc",
    "internal_observation_width": 99,
    "history_frames": 10,
    "preview_frames": 10,
    "preview_width": 73,
    "joint_velocity_feature_scale": if legacy {
      0.1
    } else {
      1.0
    },
    "body_gyro_feature_scale": if legacy {
      0.25
    } else {
      1.0
    },
    "gravity": "negative third row of root body-to-world rotation",
    "reference_orientation": "first two columns of root-transpose times reference rotation in aligned mat_to_6d order",
    "normalization": "saved actor normalization: (input - mean) / sqrt(variance + 0.01^2)",
    // Frozen v1/v2 contract text participates in artifact compatibility. The
    // separate export-lunakine command is documented outside this archive tag.
    "runtime": "native LibTorch/MoonBit archive; E1 runner masks unused outputs; no ONNX export",
    "control_hz": 50,
    "state_quaternion_order": "wxyz",
    "embedding": "physical axes occupy prefix in profile order; all remaining joint/action/state channels projected to zero",
    "action_to_setpoint": "default_q + scales * action + simulated_encoder_offset",
    "hardware_qualified": false,
  }
}
