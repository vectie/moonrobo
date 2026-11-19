///|
pub fn joint_names() -> Array[String] {
  [
    "left_hip_pitch_joint", "left_hip_roll_joint", "left_hip_yaw_joint", "left_knee_joint",
    "left_ankle_pitch_joint", "left_ankle_roll_joint", "right_hip_pitch_joint", "right_hip_roll_joint",
    "right_hip_yaw_joint", "right_knee_joint", "right_ankle_pitch_joint", "right_ankle_roll_joint",
    "waist_yaw_joint", "waist_roll_joint", "waist_pitch_joint", "left_shoulder_pitch_joint",
    "left_shoulder_roll_joint", "left_shoulder_yaw_joint", "left_elbow_joint", "left_wrist_roll_joint",
    "left_wrist_pitch_joint", "left_wrist_yaw_joint", "right_shoulder_pitch_joint",
    "right_shoulder_roll_joint", "right_shoulder_yaw_joint", "right_elbow_joint",
    "right_wrist_roll_joint", "right_wrist_pitch_joint", "right_wrist_yaw_joint",
  ]
}

///|
pub fn tracked_body_names() -> Array[String] {
  [
    "pelvis", "left_hip_roll_link", "left_knee_link", "left_ankle_roll_link", "right_hip_roll_link",
    "right_knee_link", "right_ankle_roll_link", "torso_link", "left_shoulder_roll_link",
    "left_elbow_link", "left_wrist_yaw_link", "right_shoulder_roll_link", "right_elbow_link",
    "right_wrist_yaw_link",
  ]
}

///|
pub(all) struct Motor {
  effort : Double
  velocity : Double
  armature : Double
} derive(Debug)

///|
pub fn motor_of(name : String) -> Motor raise {
  let name = name
    .replace(old="left_", new="")
    .replace(old="right_", new="")
    .replace(old="_joint", new="")
  match name {
    "hip_pitch" | "hip_yaw" | "waist_yaw" =>
      { effort: 88.0, velocity: 32.0, armature: 0.010177520, }
    "hip_roll" | "knee" =>
      { effort: 139.0, velocity: 20.0, armature: 0.025101925, }
    "ankle_pitch" | "ankle_roll" | "waist_roll" | "waist_pitch" =>
      { effort: 50.0, velocity: 37.0, armature: 2.0 * 0.003609725, }
    "shoulder_pitch"
    | "shoulder_roll"
    | "shoulder_yaw"
    | "elbow"
    | "wrist_roll" => { effort: 25.0, velocity: 37.0, armature: 0.003609725, }
    "wrist_pitch" | "wrist_yaw" =>
      { effort: 5.0, velocity: 22.0, armature: 0.00425, }
    _ => fail("unknown G1 joint: \{name}")
  }
}

///|
pub fn Motor::stiffness(self : Motor) -> Double {
  let freq = 10.0 * 2.0 * 3.1415926535
  self.armature * freq * freq
}

///|
pub fn Motor::damping(self : Motor) -> Double {
  4.0 * self.armature * 10.0 * 2.0 * 3.1415926535
}

///|
pub fn Motor::action_scale(self : Motor) -> Double {
  0.25 * self.effort / self.stiffness()
}

///|
pub fn default_joint_positions() -> Array[Double] {
  [
    -0.312, 0.0, 0.0, 0.669, -0.363, 0.0, -0.312, 0.0, 0.0, 0.669, -0.363, 0.0, 0.0,
    0.0, 0.0, 0.2, 0.2, 0.0, 0.6, 0.0, 0.0, 0.0, 0.2, -0.2, 0.0, 0.6, 0.0, 0.0, 0.0,
  ]
}

///|
pub fn action_to_setpoint(
  action : Array[Double],
  default_q~ : Array[Double] = default_joint_positions(),
  scales? : Array[Double],
  calibration? : Array[Double],
) -> Array[Double] raise {
  guard action.length() == 29 && default_q.length() == 29 else {
    fail("G1 action must have 29 joints")
  }
  let alpha = match scales {
    Some(x) => x
    None => {
      let out : Array[Double] = []
      for name in joint_names() {
        out.push(motor_of(name).action_scale())
      }
      out
    }
  }
  guard alpha.length() == 29 else {
    fail("G1 action scales must have 29 joints")
  }
  let offset = calibration.unwrap_or(Array::make(29, 0.0))
  guard offset.length() == 29 else {
    fail("G1 calibration must have 29 joints")
  }
  Array::makei(29, i => default_q[i] + alpha[i] * action[i] + offset[i])
}
