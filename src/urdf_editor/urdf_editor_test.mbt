///|
fn fixture() -> String {
  let source =
    #|<?xml version="1.0"?>
    #|<robot name="editor_bot">
    #|  <!-- preserve this comment -->
    #|  <material name="paint">
    #|    <color rgba="0.1 0.2 0.3 1"/>
    #|  </material>
    #|  <link name="base_link">
    #|    <inertial>
    #|      <origin xyz="0 0 0.05" rpy="0 0 0"/>
    #|      <mass value="12.5"/>
    #|      <inertia ixx="1" ixy="0" ixz="0" iyy="2" iyz="0" izz="3"/>
    #|    </inertial>
    #|    <visual>
    #|      <origin xyz="0 0 0" rpy="0 0 0"/>
    #|      <geometry>
    #|        <mesh filename="package://e1/meshes/base.STL" scale="1 1 1"/>
    #|      </geometry>
    #|      <material name="paint"/>
    #|    </visual>
    #|    <collision>
    #|      <origin xyz="0 0 0.1" rpy="0 0 0"/>
    #|      <geometry>
    #|        <box size="1 2 3"/>
    #|      </geometry>
    #|    </collision>
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
  assert_eq(doc.collisions.length(), 1)
  assert_eq(doc.inertials.length(), 1)
  assert_eq(doc.materials.length(), 2)
  assert_eq(doc.links[0].node_id, "link:base_link")
  assert_eq(doc.joints[0].node_id, "joint:shoulder_joint")
  assert_eq(doc.visuals[0].node_id, "visual:base_link:0")
  assert_eq(doc.collisions[0].node_id, "collision:base_link:0")
  assert_eq(doc.inertials[0].node_id, "inertial:base_link")
  assert_eq(doc.materials[0].node_id, "material:robot:paint")
  assert_eq(doc.materials[1].node_id, "material:base_link:visual:0")
  assert_eq(doc.visuals[0].mesh_filename, "package://e1/meshes/base.STL")
  assert_eq(doc.collisions[0].geometry_kind, "box")
  assert_eq(doc.collisions[0].size, "1 2 3")
  assert_true(doc.inertials[0].mass is Some(12.5))
  assert_true(doc.inertials[0].iyy is Some(2.0))
  assert_eq(doc.materials[0].color_rgba, "0.1 0.2 0.3 1")
  assert_true(doc.materials[0].color_source_span is Some(_))
  assert_eq(doc.materials[1].name, "paint")
  assert_true(doc.joints[0].origin is Some(_))
  assert_true(doc.joints[0].limit is Some(_))
  assert_true(doc.collisions[0].origin is Some(_))
  assert_eq(doc.issues.length(), 0)
}

///|
test "urdf editor builds component tree and selection inspector" {
  let doc = parse_document(fixture())
  let rows = component_tree(doc)
  assert_eq(rows.length(), 9)
  assert_eq(rows[0].node_id, "robot")
  assert_eq(rows[0].kind, "robot")
  assert_true(rows.any(fn(row) { row.node_id == "link:base_link" }))
  assert_true(rows.any(fn(row) { row.node_id == "joint:shoulder_joint" }))
  assert_true(rows.any(fn(row) { row.node_id == "visual:base_link:0" }))
  assert_true(rows.any(fn(row) { row.node_id == "collision:base_link:0" }))
  assert_true(rows.any(fn(row) { row.node_id == "inertial:base_link" }))
  assert_true(rows.any(fn(row) { row.node_id == "material:robot:paint" }))
  assert_true(
    rows.any(fn(row) { row.node_id == "material:base_link:visual:0" }),
  )
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
  match select_component(doc, "collision:base_link:0") {
    Some(detail) => {
      assert_eq(detail.kind, "collision")
      assert_eq(detail.commands.length(), 1)
      assert_true(detail.commands.contains("update-collision-origin"))
      assert_true(
        detail.fields.any(fn(item) {
          item.name == "size" && item.value == "1 2 3"
        }),
      )
    }
    None => fail("expected collision selection")
  }
  match select_component(doc, "inertial:base_link") {
    Some(detail) => {
      assert_eq(detail.kind, "inertial")
      assert_true(
        detail.fields.any(fn(item) {
          item.name == "mass" && item.value == "12.5"
        }),
      )
      assert_true(
        detail.fields.any(fn(item) { item.name == "iyy" && item.value == "2" }),
      )
    }
    None => fail("expected inertial selection")
  }
  match select_component(doc, "material:robot:paint") {
    Some(detail) => {
      assert_eq(detail.kind, "material")
      assert_true(detail.commands.contains("update-material"))
      assert_true(
        detail.fields.any(fn(item) {
          item.name == "color rgba" &&
          item.value == "0.1 0.2 0.3 1" &&
          item.editable
        }),
      )
    }
    None => fail("expected global material selection")
  }
  match select_component(doc, "material:base_link:visual:0") {
    Some(detail) => {
      assert_eq(detail.kind, "material")
      assert_true(
        detail.fields.any(fn(item) {
          item.name == "visual index" && item.value == "0"
        }),
      )
    }
    None => fail("expected visual material selection")
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
test "urdf editor updates collision origin while preserving visual mesh source" {
  match
    update_collision_origin(fixture(), "base_link", 0, {
      xyz: "0.4 0.5 0.6",
      rpy: "0.7 0.8 0.9",
    }) {
    Ok(edit) => {
      assert_true(
        edit.source.contains(
          "<origin xyz=\"0.4 0.5 0.6\" rpy=\"0.7 0.8 0.9\"/>",
        ),
      )
      assert_true(edit.source.contains("package://e1/meshes/base.STL"))
      assert_true(edit.source.contains("<box size=\"1 2 3\"/>"))
      let doc = parse_document(edit.source)
      match doc.collisions[0].origin {
        Some(origin) => {
          assert_eq(origin.xyz, "0.4 0.5 0.6")
          assert_eq(origin.rpy, "0.7 0.8 0.9")
        }
        None => fail("expected collision origin")
      }
    }
    Err(error) => fail(error.message)
  }
}

///|
test "urdf editor updates inertial block while preserving visual and material source" {
  match
    update_inertial(fixture(), "base_link", {
      origin: Some({ xyz: "0.1 0.2 0.3", rpy: "0.4 0.5 0.6" }),
      mass: Some(20.0),
      ixx: Some(4.0),
      ixy: Some(0.1),
      ixz: Some(0.2),
      iyy: Some(5.0),
      iyz: Some(0.3),
      izz: Some(6.0),
    }) {
    Ok(edit) => {
      assert_true(edit.source.contains("<inertial>"))
      assert_true(
        edit.source.contains(
          "<origin xyz=\"0.1 0.2 0.3\" rpy=\"0.4 0.5 0.6\"/>",
        ),
      )
      assert_true(edit.source.contains("<mass value=\"20\"/>"))
      assert_true(
        edit.source.contains(
          "<inertia ixx=\"4\" ixy=\"0.1\" ixz=\"0.2\" iyy=\"5\" iyz=\"0.3\" izz=\"6\"/>",
        ),
      )
      assert_true(edit.source.contains("package://e1/meshes/base.STL"))
      assert_true(edit.source.contains("<material name=\"paint\"/>"))
      let doc = parse_document(edit.source)
      assert_true(doc.inertials[0].mass is Some(20.0))
      assert_true(doc.inertials[0].izz is Some(6.0))
      assert_eq(doc.issues.length(), 0)
    }
    Err(error) => fail(error.message)
  }
}

///|
test "urdf editor inserts missing inertial before link close" {
  let source =
    #|<robot name="insert_inertial_bot">
    #|  <link name="base">
    #|    <visual><geometry><box size="1 1 1"/></geometry></visual>
    #|  </link>
    #|</robot>
  match
    update_inertial(source, "base", {
      origin: Some({ xyz: "0 0 0", rpy: "0 0 0" }),
      mass: Some(1.0),
      ixx: Some(1.0),
      ixy: Some(0.0),
      ixz: Some(0.0),
      iyy: Some(1.0),
      iyz: Some(0.0),
      izz: Some(1.0),
    }) {
    Ok(edit) => {
      assert_true(edit.source.contains("<inertial>"))
      assert_true(edit.source.find("<inertial>") is Some(_))
      let doc = parse_document(edit.source)
      assert_eq(doc.inertials.length(), 1)
      assert_true(doc.inertials[0].mass is Some(1.0))
    }
    Err(error) => fail(error.message)
  }
}

///|
test "urdf editor updates material color and inserts texture without touching visual reference" {
  match
    update_material(fixture(), "material:robot:paint", {
      color_rgba: Some("0.9 0.1 0.2 1"),
      texture_filename: Some("textures/paint.png"),
    }) {
    Ok(edit) => {
      assert_true(edit.changed)
      assert_true(edit.source.contains("<!-- preserve this comment -->"))
      assert_true(edit.source.contains("<color rgba=\"0.9 0.1 0.2 1\"/>"))
      assert_true(
        edit.source.contains("<texture filename=\"textures/paint.png\"/>"),
      )
      assert_true(edit.source.contains("<material name=\"paint\"/>"))
      let doc = parse_document(edit.source)
      assert_eq(doc.materials[0].color_rgba, "0.9 0.1 0.2 1")
      assert_eq(doc.materials[0].texture_filename, "textures/paint.png")
      assert_eq(doc.materials[1].name, "paint")
      assert_eq(doc.issues.length(), 0)
    }
    Err(error) => fail(error.message)
  }
}

///|
test "urdf editor expands self-closing visual material for inline editing" {
  match
    update_material(fixture(), "material:base_link:visual:0", {
      color_rgba: Some("0.2 0.8 0.4 1"),
      texture_filename: None,
    }) {
    Ok(edit) => {
      assert_true(edit.changed)
      assert_true(edit.source.contains("<material name=\"paint\">\n"))
      assert_true(edit.source.contains("<color rgba=\"0.2 0.8 0.4 1\"/>"))
      assert_true(edit.source.contains("package://e1/meshes/base.STL"))
      let doc = parse_document(edit.source)
      assert_eq(doc.materials[1].scope, "visual")
      assert_eq(doc.materials[1].color_rgba, "0.2 0.8 0.4 1")
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
