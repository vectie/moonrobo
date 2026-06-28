///|
test "Noetix Moonmoon locomotion contract is ready and source-backed" {
  let contract = noetix_e1_moonmoon_locomotion_contract()
  assert_true(contract.ready)
  assert_eq(contract.status, "moonmoon-noetix-locomotion-contract-ready")
  assert_eq(contract.robot_id, "noetix-e1-lab-01")
  assert_eq(contract.platform, "noetix-e1")
  assert_eq(contract.profile_path, "examples/noetix-e1/robot.json")
  assert_eq(
    contract.urdf_path,
    "examples/noetix-e1/e1_asm_251028/urdf/e1_asm.urdf",
  )
  assert_eq(contract.mesh_paths.length(), 25)
  assert_eq(contract.expected_profile_joint_count, 24)
  assert_eq(contract.profile_joint_ids.length(), 24)
  assert_true(contract.profile_joint_ids.contains("leg_l1_joint"))
  assert_true(contract.profile_joint_ids.contains("leg_r6_joint"))
  assert_true(contract.profile_joint_ids.contains("arm_l1_joint"))
  assert_true(contract.profile_joint_ids.contains("arm_r4_joint"))
  assert_true(contract.required_motion_joint_ids.contains("leg_l4_joint"))
  assert_true(contract.required_motion_joint_ids.contains("arm_r4_joint"))
  assert_true(contract.walk_clip.ready)
  assert_eq(contract.walk_clip.status, "moonmoon-noetix-walk-clip-ready")
  assert_eq(contract.walk_clip.clip_id, "noetix-e1-lab-01/endless-forward-walk")
  assert_eq(contract.walk_clip.sample_count, 24)
  assert_true(contract.walk_clip.required_joint_ids.contains("leg_l4_joint"))
  assert_true(contract.walk_clip.required_joint_ids.contains("arm_r4_joint"))
  assert_true(
    contract.mesh_paths.contains(
      "examples/noetix-e1/e1_asm_251028/meshes/base_link.STL",
    ),
  )
  assert_true(
    contract.mesh_paths.contains(
      "examples/noetix-e1/e1_asm_251028/meshes/r_leg_ankle_roll_link.STL",
    ),
  )
  assert_eq(
    contract.target_payload_type,
    "vectie/moonmoon/src/suite_adapter_preview.NoetixSuiteAdapterPayload",
  )
}

///|
test "Noetix Moonmoon locomotion source refs name profile URDF and mesh" {
  let refs = noetix_e1_moonmoon_source_refs()
  assert_eq(refs.length(), 6)
  assert_true(
    refs.any(fn(source) {
      source.source_family == "moonrobo.robot-profile" &&
      source.local_path == "examples/noetix-e1/robot.json"
    }),
  )
  assert_true(
    refs.any(fn(source) {
      source.source_family == "moonrobo.urdf" &&
      source.local_path == "examples/noetix-e1/model/robot.urdf"
    }),
  )
  assert_true(
    refs.any(fn(source) {
      source.source_family == "moonrobo.mesh" &&
      source.local_path == "examples/noetix-e1/model/meshes/base.obj"
    }),
  )
  assert_true(
    refs.any(fn(source) {
      source.source_family == "moonrobo.urdf-package" &&
      source.local_path == "examples/noetix-e1/e1_asm_251028" &&
      source.status == "local-ignored-source"
    }),
  )
  assert_true(
    refs.any(fn(source) {
      source.source_family == "moonrobo.urdf" &&
      source.local_path == "examples/noetix-e1/e1_asm_251028/urdf/e1_asm.urdf" &&
      source.status == "local-ignored-source"
    }),
  )
  assert_true(
    refs.any(fn(source) {
      source.source_family == "moonrobo.mesh-dir" &&
      source.local_path == "examples/noetix-e1/e1_asm_251028/meshes" &&
      source.status == "local-ignored-source"
    }),
  )
}
