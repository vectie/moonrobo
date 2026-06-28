///|
pub(all) struct MoonmoonAdapterSourceRef {
  source_id : String
  source_family : String
  local_path : String
  role : String
  status : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonmoonNoetixLocomotionContract {
  contract_id : String
  target_payload_type : String
  robot_id : String
  robot_label : String
  platform : String
  profile_path : String
  urdf_path : String
  mesh_paths : Array[String]
  expected_profile_joint_count : Int
  profile_joint_ids : Array[String]
  required_motion_joint_ids : Array[String]
  walk_clip : MoonmoonNoetixWalkClipContract
  source_refs : Array[MoonmoonAdapterSourceRef]
  blocker_count : Int
  blockers : Array[String]
  ready : Bool
  status : String
} derive(Debug, Eq, ToJson, FromJson)

///|
fn source_ref(
  source_id : String,
  source_family : String,
  local_path : String,
  role : String,
  status : String,
) -> MoonmoonAdapterSourceRef {
  { source_id, source_family, local_path, role, status }
}

///|
pub fn noetix_e1_moonmoon_required_motion_joint_ids() -> Array[String] {
  [
    "leg_l1_joint", "leg_l4_joint", "leg_l6_joint", "leg_r1_joint", "leg_r4_joint",
    "leg_r6_joint", "arm_l1_joint", "arm_l4_joint", "arm_r1_joint", "arm_r4_joint",
  ]
}

///|
pub fn noetix_e1_extracted_example_root() -> String {
  "examples/noetix-e1/e1_asm_251028"
}

///|
pub fn noetix_e1_extracted_urdf_path() -> String {
  noetix_e1_extracted_example_root() + "/urdf/e1_asm.urdf"
}

///|
pub fn noetix_e1_extracted_mesh_dir() -> String {
  noetix_e1_extracted_example_root() + "/meshes"
}

///|
pub fn noetix_e1_extracted_stl_mesh_paths() -> Array[String] {
  let mesh_dir = noetix_e1_extracted_mesh_dir()
  [
    "\{mesh_dir}/base_link.STL",
    "\{mesh_dir}/waist_yaw_link.STL",
    "\{mesh_dir}/waist_roll_link.STL",
    "\{mesh_dir}/l_arm_shoulder_pitch_link.STL",
    "\{mesh_dir}/l_arm_shoulder_roll_link.STL",
    "\{mesh_dir}/l_arm_shoulder_yaw_link.STL",
    "\{mesh_dir}/l_arm_elbow_pitch_link.STL",
    "\{mesh_dir}/l_arm_elbow_yaw_link.STL",
    "\{mesh_dir}/r_arm_shoulder_pitch_link.STL",
    "\{mesh_dir}/r_arm_shoulder_roll_link.STL",
    "\{mesh_dir}/r_arm_shoulder_yaw_link.STL",
    "\{mesh_dir}/r_arm_elbow_pitch_link.STL",
    "\{mesh_dir}/r_arm_elbow_yaw_link.STL",
    "\{mesh_dir}/l_leg_hip_yaw_link.STL",
    "\{mesh_dir}/l_leg_hip_roll_link.STL",
    "\{mesh_dir}/l_leg_hip_pitch_link.STL",
    "\{mesh_dir}/l_leg_knee_link.STL",
    "\{mesh_dir}/l_leg_ankle_pitch_link.STL",
    "\{mesh_dir}/l_leg_ankle_roll_link.STL",
    "\{mesh_dir}/r_leg_hip_yaw_link.STL",
    "\{mesh_dir}/r_leg_hip_roll_link.STL",
    "\{mesh_dir}/r_leg_hip_pitch_link.STL",
    "\{mesh_dir}/r_leg_knee_link.STL",
    "\{mesh_dir}/r_leg_ankle_pitch_link.STL",
    "\{mesh_dir}/r_leg_ankle_roll_link.STL",
  ]
}

///|
pub fn noetix_e1_moonmoon_source_refs() -> Array[MoonmoonAdapterSourceRef] {
  [
    source_ref(
      "moonrobo-noetix-e1-profile", "moonrobo.robot-profile", "examples/noetix-e1/robot.json",
      "Noetix robot profile, bridge limits, capabilities, and model references",
      "typed-source",
    ),
    source_ref(
      "moonrobo-noetix-e1-urdf", "moonrobo.urdf", "examples/noetix-e1/model/robot.urdf",
      "Noetix joint tree, axes, limits, link visuals, and mesh references", "typed-source",
    ),
    source_ref(
      "moonrobo-noetix-e1-base-mesh", "moonrobo.mesh", "examples/noetix-e1/model/meshes/base.obj",
      "base_link visual mesh referenced by the URDF", "typed-source",
    ),
    source_ref(
      "moonrobo-noetix-e1-extracted-package",
      "moonrobo.urdf-package",
      noetix_e1_extracted_example_root(),
      "ignored local Noetix E1 extracted package with original ROS folder structure",
      "local-ignored-source",
    ),
    source_ref(
      "moonrobo-noetix-e1-extracted-urdf",
      "moonrobo.urdf",
      noetix_e1_extracted_urdf_path(),
      "raw E1 assembly URDF from the ignored local package",
      "local-ignored-source",
    ),
    source_ref(
      "moonrobo-noetix-e1-extracted-meshes",
      "moonrobo.mesh-dir",
      noetix_e1_extracted_mesh_dir(),
      "25 STL meshes from the ignored local E1 package",
      "local-ignored-source",
    ),
  ]
}

///|
fn missing_required_joint_ids(
  profile_joint_ids : Array[String],
) -> Array[String] {
  let missing : Array[String] = []
  for joint_id in noetix_e1_moonmoon_required_motion_joint_ids() {
    if !profile_joint_ids.contains(joint_id) {
      missing.push(joint_id)
    }
  }
  missing
}

///|
fn noetix_contract_blockers(
  profile : @core.RobotProfile,
  profile_joint_ids : Array[String],
) -> Array[String] {
  let blockers : Array[String] = []
  let validation = @core.validate_robot_profile(profile)
  if !validation.valid {
    blockers.push("profile-invalid")
  }
  if profile.kind != Humanoid {
    blockers.push("profile-kind-not-humanoid")
  }
  if profile.platform != "noetix-e1" {
    blockers.push("profile-platform:\{profile.platform}")
  }
  if profile.model.primary != "model/robot.urdf" {
    blockers.push("profile-primary-model:\{profile.model.primary}")
  }
  if profile.bridge.config_path != "bridge/bridge.json" {
    blockers.push("profile-bridge-config:\{profile.bridge.config_path}")
  }
  if profile.joints.length() != 24 {
    blockers.push("profile-joint-count:\{profile.joints.length()}")
  }
  for missing in missing_required_joint_ids(profile_joint_ids) {
    blockers.push("missing-motion-joint:\{missing}")
  }
  let walk_clip = noetix_e1_moonmoon_walk_clip_contract()
  if !walk_clip.ready {
    blockers.push("walk-clip:\{walk_clip.status}")
  }
  for blocker in walk_clip.blockers {
    blockers.push("walk-clip-blocker:\{blocker}")
  }
  blockers
}

///|
pub fn noetix_e1_moonmoon_locomotion_contract(
  robot_id? : String = "noetix-e1-lab-01",
  robot_label? : String = "Noetix E1 Lab 01",
) -> MoonmoonNoetixLocomotionContract {
  let profile = @core.noetix_e1_profile(robot_id, robot_label)
  let profile_joint_ids = profile.joints.map(fn(joint) { joint.name })
  let blockers = noetix_contract_blockers(profile, profile_joint_ids)
  {
    contract_id: "\{profile.id}/moonmoon-locomotion-source-contract",
    target_payload_type: "vectie/moonmoon/src/suite_adapter_preview.NoetixSuiteAdapterPayload",
    robot_id: profile.id,
    robot_label: profile.label,
    platform: profile.platform,
    profile_path: "examples/noetix-e1/robot.json",
    urdf_path: noetix_e1_extracted_urdf_path(),
    mesh_paths: noetix_e1_extracted_stl_mesh_paths(),
    expected_profile_joint_count: 24,
    profile_joint_ids,
    required_motion_joint_ids: noetix_e1_moonmoon_required_motion_joint_ids(),
    walk_clip: noetix_e1_moonmoon_walk_clip_contract(),
    source_refs: noetix_e1_moonmoon_source_refs(),
    blocker_count: blockers.length(),
    blockers,
    ready: blockers.is_empty(),
    status: if blockers.is_empty() {
      "moonmoon-noetix-locomotion-contract-ready"
    } else {
      "moonmoon-noetix-locomotion-contract-blocked"
    },
  }
}
