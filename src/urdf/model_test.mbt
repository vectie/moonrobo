///|
fn fixture() -> String raise {
  @fsx.read_file_to_string("examples/noetix-e1/model/robot.urdf") catch {
    _ => fail("failed to read URDF fixture")
  }
}

///|
test "URDF parser extracts Noetix links joints and limits" {
  let model = @urdf.parse(fixture())
  assert_eq(model.robot_name, "noetix_e1_lab_01")
  assert_eq(model.joint_count, 24)
  assert_eq(model.visual_count, 6)
  assert_true(model.link_count >= 25)
  assert_true(@urdf.has_link(model, "base_link"))
  assert_true(@urdf.has_joint(model, "arm_l1_joint"))
  assert_true(@urdf.has_joint(model, "leg_r6_joint"))
  let waist = @urdf.find_joint(model, "waist_1_joint").unwrap()
  assert_eq(waist.joint_type, "revolute")
  assert_eq(waist.parent_link, "base_link")
  assert_eq(waist.child_link, "torso_link")
  assert_eq(waist.origin.xyz, "0 0 0.32")
  assert_eq(waist.origin.rpy, "0 0 0")
  assert_eq(waist.origin.z, 0.32)
  assert_true(waist.limit is Some({ lower: Some(-0.8), upper: Some(0.8), .. }))
  assert_eq(model.issues.length(), 0)
}

///|
test "URDF parser extracts visual mesh and primitive geometry" {
  let model = @urdf.parse(
    (
      #|<robot name="visual_bot">
      #|  <link name="base">
      #|    <visual>
      #|      <origin xyz="0 0 0.1" rpy="0 0 0"/>
      #|      <geometry>
      #|        <mesh filename="meshes/base.obj" scale="1 1 1"/>
      #|      </geometry>
      #|    </visual>
      #|  </link>
      #|  <link name="arm">
      #|    <visual>
      #|      <geometry>
      #|        <box size="0.1 0.2 0.3"/>
      #|      </geometry>
      #|    </visual>
      #|  </link>
      #|</robot>
    ),
  )
  assert_eq(model.robot_name, "visual_bot")
  assert_eq(model.link_count, 2)
  assert_eq(model.visual_count, 2)
  assert_eq(model.visuals[0].link_name, "base")
  assert_eq(model.visuals[0].geometry_kind, "mesh")
  assert_eq(model.visuals[0].mesh_filename, "meshes/base.obj")
  assert_eq(model.visuals[0].mesh_scale, "1 1 1")
  assert_eq(model.visuals[0].origin.z, 0.1)
  assert_eq(model.visuals[1].link_name, "arm")
  assert_eq(model.visuals[1].geometry_kind, "box")
  assert_eq(model.visuals[1].size, "0.1 0.2 0.3")
}

///|
test "URDF parser reports malformed model diagnostics" {
  let model = @urdf.parse(
    "<robot><joint name=\"broken\" type=\"revolute\"></robot>",
  )
  assert_eq(model.robot_name, "")
  assert_eq(model.joint_count, 0)
  assert_true(model.issues.contains("robot tag missing name"))
  assert_true(
    model.issues.any(fn(issue) { issue.contains("unterminated joint") }),
  )
}
