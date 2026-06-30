///|
fn fixture() -> String {
  let source =
    #|<?xml version="1.0"?>
    #|<robot name="editor_bot">
    #|  <!-- preserve this comment -->
    #|  <link name="base_link">
    #|    <visual>
    #|      <origin xyz="0 0 0" rpy="0 0 0"/>
    #|      <geometry>
    #|        <mesh filename="package://e1/meshes/base.STL" scale="1 1 1"/>
    #|      </geometry>
    #|    </visual>
    #|  </link>
    #|  <link name="arm_link"/>
    #|  <joint name="shoulder_joint" type="revolute">
    #|    <parent link="base_link"/>
    #|    <child link="arm_link"/>
    #|    <origin xyz="0 0 1" rpy="0 0 0"/>
    #|    <axis xyz="0 0 1"/>
    #|    <limit lower="-1" upper="1" effort="20" velocity="2"/>
    #|  </joint>
    #|</robot>
  source
}

///|
test "urdf editor parses stable source-backed document nodes" {
  let doc = parse_document(fixture())
  assert_eq(doc.robot_name, "editor_bot")
  assert_eq(doc.links.length(), 2)
  assert_eq(doc.joints.length(), 1)
  assert_eq(doc.visuals.length(), 1)
  assert_eq(doc.links[0].node_id, "link:base_link")
  assert_eq(doc.joints[0].node_id, "joint:shoulder_joint")
  assert_eq(doc.visuals[0].node_id, "visual:base_link:0")
  assert_eq(doc.visuals[0].mesh_filename, "package://e1/meshes/base.STL")
  assert_true(doc.joints[0].origin is Some(_))
  assert_true(doc.joints[0].limit is Some(_))
  assert_eq(doc.issues.length(), 0)
}

///|
test "urdf editor builds component tree and selection inspector" {
  let doc = parse_document(fixture())
  let rows = component_tree(doc)
  assert_eq(rows.length(), 5)
  assert_eq(rows[0].node_id, "robot")
  assert_eq(rows[0].kind, "robot")
  assert_true(rows.any(fn(row) { row.node_id == "link:base_link" }))
  assert_true(rows.any(fn(row) { row.node_id == "joint:shoulder_joint" }))
  assert_true(rows.any(fn(row) { row.node_id == "visual:base_link:0" }))
  match select_component(doc, "joint:shoulder_joint") {
    Some(detail) => {
      assert_eq(detail.kind, "joint")
      assert_eq(detail.label, "shoulder_joint")
      assert_true(detail.commands.contains("update-joint-origin"))
      assert_true(detail.commands.contains("update-joint-limit"))
      assert_true(
        detail.fields.any(fn(item) { item.name == "origin" && item.editable }),
      )
    }
    None => fail("expected joint selection")
  }
  match select_component(doc, "visual:base_link:0") {
    Some(detail) => {
      assert_eq(detail.kind, "visual")
      assert_eq(detail.commands.length(), 1)
      assert_true(detail.commands.contains("update-visual-origin"))
      assert_true(
        detail.fields.any(fn(item) {
          item.name == "mesh" && item.value.contains("base.STL")
        }),
      )
    }
    None => fail("expected visual selection")
  }
  assert_eq(select_component(doc, "missing") is None, true)
}

///|
test "urdf editor updates only the selected joint limit tag" {
  let result = update_joint_limit(fixture(), "shoulder_joint", {
    lower: Some(-2.0),
    upper: Some(2.0),
    effort: Some(30.0),
    velocity: Some(3.0),
  })
  match result {
    Ok(edit) => {
      assert_true(edit.changed)
      assert_true(edit.source.contains("<!-- preserve this comment -->"))
      assert_true(
        edit.source.contains(
          "<limit lower=\"-2\" upper=\"2\" effort=\"30\" velocity=\"3\"/>",
        ),
      )
      assert_true(
        edit.source.contains(
          "<mesh filename=\"package://e1/meshes/base.STL\" scale=\"1 1 1\"/>",
        ),
      )
      assert_eq(parse_document(edit.source).issues.length(), 0)
    }
    Err(error) => fail(error.message)
  }
}

///|
test "urdf editor inserts missing joint limit before joint close" {
  let source =
    #|<robot name="insert_bot">
    #|  <link name="a"/>
    #|  <link name="b"/>
    #|  <joint name="j" type="prismatic">
    #|    <parent link="a"/>
    #|    <child link="b"/>
    #|  </joint>
    #|</robot>
  match
    update_joint_limit(source, "j", {
      lower: Some(0.0),
      upper: Some(1.0),
      effort: None,
      velocity: Some(4.0),
    }) {
    Ok(edit) => {
      assert_true(
        edit.source.contains("<limit lower=\"0\" upper=\"1\" velocity=\"4\"/>"),
      )
      assert_true(edit.source.find("<limit") is Some(_))
      assert_eq(parse_document(edit.source).joints[0].limit is Some(_), true)
    }
    Err(error) => fail(error.message)
  }
}

///|
test "urdf editor updates visual origin while preserving mesh source" {
  match
    update_visual_origin(fixture(), "base_link", 0, {
      xyz: "1 2 3",
      rpy: "0.1 0.2 0.3",
    }) {
    Ok(edit) => {
      assert_true(
        edit.source.contains("<origin xyz=\"1 2 3\" rpy=\"0.1 0.2 0.3\"/>"),
      )
      assert_true(edit.source.contains("package://e1/meshes/base.STL"))
      let doc = parse_document(edit.source)
      match doc.visuals[0].origin {
        Some(origin) => {
          assert_eq(origin.xyz, "1 2 3")
          assert_eq(origin.rpy, "0.1 0.2 0.3")
        }
        None => fail("expected visual origin")
      }
    }
    Err(error) => fail(error.message)
  }
}

///|
test "urdf editor rejects invalid limit order" {
  match
    update_joint_limit(fixture(), "shoulder_joint", {
      lower: Some(3.0),
      upper: Some(1.0),
      effort: None,
      velocity: None,
    }) {
    Ok(_) => fail("expected invalid limit order")
    Err(error) => assert_eq(error.code, "joint-limit-order")
  }
}

///|
test "urdf editor validates duplicate names and missing topology" {
  let source =
    #|<robot name="bad">
    #|  <link name="base"/>
    #|  <link name="base"/>
    #|  <joint name="j" type="fixed">
    #|    <parent link="base"/>
    #|    <child link="missing"/>
    #|  </joint>
    #|</robot>
  let doc = parse_document(source)
  assert_true(doc.issues.any(fn(item) { item.code == "duplicate-link" }))
  assert_true(doc.issues.any(fn(item) { item.code == "joint-child-unknown" }))
}
