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
    #|  <link name="arm_link">
    #|    <inertial>
    #|      <mass value="1"/>
    #|      <inertia ixx="1" ixy="0" ixz="0" iyy="1" iyz="0" izz="1"/>
    #|    </inertial>
    #|  </link>
    #|  <joint name="shoulder_joint" type="revolute">
    #|    <parent link="base_link"/>
    #|    <child link="arm_link"/>
    #|    <origin xyz="0 0 1" rpy="0 0 0"/>
    #|    <axis xyz="0 0 1"/>
    #|    <limit lower="-1" upper="1" effort="20" velocity="2"/>
    #|    <dynamics damping="0.1" friction="0.2"/>
    #|    <calibration rising="0.01" falling="-0.01"/>
    #|    <safety_controller soft_lower_limit="-0.8" soft_upper_limit="0.8" k_position="10" k_velocity="2"/>
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
  assert_eq(doc.inertials.length(), 2)
  assert_eq(doc.materials.length(), 2)
  assert_eq(doc.extensions.length(), 1)
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
  assert_eq(doc.extensions[0].node_id, "extension:comment:0")
  assert_eq(doc.extensions[0].kind, "comment")
  assert_eq(doc.extensions[0].parent_id, "robot")
  assert_true(doc.joints[0].origin is Some(_))
  assert_true(doc.joints[0].limit is Some(_))
  assert_true(doc.joints[0].dynamics is Some(_))
  assert_true(doc.joints[0].calibration is Some(_))
  assert_true(doc.joints[0].safety_controller is Some(_))
  assert_true(doc.collisions[0].origin is Some(_))
  assert_eq(doc.issues.length(), 0)
}

///|
test "urdf editor validates semantic topology and authoring rules" {
  let source =
    #|<robot name="validation_bot">
    #|  <link name="base">
    #|    <visual><geometry><box size="1 1 1"/></geometry></visual>
    #|  </link>
    #|  <link name="tool">
    #|    <collision><geometry><sphere radius="0.5"/></geometry></collision>
    #|  </link>
    #|  <joint name="fixed_tool" type="fixed">
    #|    <parent link="base"/>
    #|    <child link="tool"/>
    #|    <axis xyz="0 0 1"/>
    #|    <limit lower="0" upper="1"/>
    #|  </joint>
    #|  <joint name="continuous_tool" type="continuous">
    #|    <parent link="tool"/>
    #|    <child link="missing"/>
    #|    <limit lower="-1" upper="1"/>
    #|  </joint>
    #|</robot>
  let doc = parse_document(source)
  assert_true(
    doc.issues.any(fn(item) {
      item.code == "link-inertial-missing" &&
      item.node_id == "link:base" &&
      item.severity == Warning
    }),
  )
  assert_true(
    doc.issues.any(fn(item) {
      item.code == "link-collision-missing" && item.node_id == "link:base"
    }),
  )
  assert_true(
    doc.issues.any(fn(item) {
      item.code == "link-visual-missing" && item.node_id == "link:tool"
    }),
  )
  assert_true(
    doc.issues.any(fn(item) {
      item.code == "fixed-joint-axis" &&
      item.node_id == "joint:fixed_tool" &&
      item.severity == Warning
    }),
  )
  assert_true(
    doc.issues.any(fn(item) {
      item.code == "fixed-joint-limit" && item.node_id == "joint:fixed_tool"
    }),
  )
  assert_true(
    doc.issues.any(fn(item) {
      item.code == "continuous-joint-position-limit" &&
      item.node_id == "joint:continuous_tool"
    }),
  )
  assert_true(
    doc.issues.any(fn(item) {
      item.code == "joint-child-unknown" &&
      item.node_id == "joint:continuous_tool" &&
      item.severity == Error
    }),
  )
  match select_component(doc, "link:base") {
    Some(detail) =>
      assert_true(
        detail.issues.any(fn(item) { item.code == "link-collision-missing" }),
      )
    None => fail("expected base link selection")
  }
}

///|
test "urdf editor validates disconnected topology" {
  let source =
    #|<robot name="cycle_bot">
    #|  <link name="a"/>
    #|  <link name="b"/>
    #|  <joint name="a_to_b" type="fixed">
    #|    <parent link="a"/>
    #|    <child link="b"/>
    #|  </joint>
    #|  <joint name="b_to_a" type="fixed">
    #|    <parent link="b"/>
    #|    <child link="a"/>
    #|  </joint>
    #|</robot>
  let doc = parse_document(source)
  assert_true(
    doc.issues.any(fn(item) {
      item.code == "root-link-missing" && item.severity == Error
    }),
  )
  assert_true(
    doc.issues.any(fn(item) {
      item.code == "topology-disconnected" && item.severity == Error
    }),
  )
}

///|
test "urdf editor builds component tree and selection inspector" {
  let doc = parse_document(fixture())
  let rows = component_tree(doc)
  assert_eq(rows.length(), 11)
  assert_eq(rows[0].node_id, "robot")
  assert_eq(rows[0].kind, "robot")
  assert_eq(rows[0].command_count, 2)
  assert_true(rows.any(fn(row) { row.node_id == "link:base_link" }))
  assert_true(rows.any(fn(row) { row.node_id == "joint:shoulder_joint" }))
  assert_true(rows.any(fn(row) { row.node_id == "visual:base_link:0" }))
  assert_true(rows.any(fn(row) { row.node_id == "collision:base_link:0" }))
  assert_true(rows.any(fn(row) { row.node_id == "inertial:base_link" }))
  assert_true(rows.any(fn(row) { row.node_id == "inertial:arm_link" }))
  assert_true(rows.any(fn(row) { row.node_id == "material:robot:paint" }))
  assert_true(
    rows.any(fn(row) { row.node_id == "material:base_link:visual:0" }),
  )
  assert_true(rows.any(fn(row) { row.node_id == "extension:comment:0" }))
  match select_component(doc, "link:base_link") {
    Some(detail) => {
      assert_eq(detail.kind, "link")
      assert_eq(detail.commands.length(), 3)
      assert_true(detail.commands.contains("rename-link"))
      assert_true(detail.commands.contains("add-visual"))
      assert_true(detail.commands.contains("add-collision"))
      assert_true(
        detail.fields.any(fn(item) { item.name == "name" && item.editable }),
      )
    }
    None => fail("expected link selection")
  }
  match select_component(doc, "robot") {
    Some(detail) => {
      assert_true(detail.commands.contains("add-link"))
      assert_true(detail.commands.contains("add-joint"))
    }
    None => fail("expected robot selection")
  }
  match select_component(doc, "joint:shoulder_joint") {
    Some(detail) => {
      assert_eq(detail.kind, "joint")
      assert_eq(detail.label, "shoulder_joint")
      assert_true(detail.commands.contains("rename-joint"))
      assert_true(detail.commands.contains("update-joint-origin"))
      assert_true(detail.commands.contains("update-joint-axis"))
      assert_true(detail.commands.contains("update-joint-limit"))
      assert_true(detail.commands.contains("update-joint-dynamics"))
      assert_true(detail.commands.contains("update-joint-mimic"))
      assert_true(detail.commands.contains("update-joint-calibration"))
      assert_true(detail.commands.contains("update-joint-safety-controller"))
      assert_true(
        detail.fields.any(fn(item) { item.name == "name" && item.editable }),
      )
      assert_true(
        detail.fields.any(fn(item) { item.name == "origin" && item.editable }),
      )
      assert_true(
        detail.fields.any(fn(item) { item.name == "axis" && item.editable }),
      )
      assert_true(
        detail.fields.any(fn(item) { item.name == "dynamics" && item.editable }),
      )
      assert_true(
        detail.fields.any(fn(item) { item.name == "mimic" && item.editable }),
      )
      assert_true(
        detail.fields.any(fn(item) {
          item.name == "calibration" && item.editable
        }),
      )
      assert_true(
        detail.fields.any(fn(item) {
          item.name == "safety controller" && item.editable
        }),
      )
    }
    None => fail("expected joint selection")
  }
  match select_component(doc, "visual:base_link:0") {
    Some(detail) => {
      assert_eq(detail.kind, "visual")
      assert_eq(detail.commands.length(), 3)
      assert_true(detail.commands.contains("update-visual-origin"))
      assert_true(detail.commands.contains("update-visual-geometry"))
      assert_true(detail.commands.contains("remove-visual"))
      assert_true(
        detail.fields.any(fn(item) {
          item.name == "mesh" &&
          item.value.contains("base.STL") &&
          item.editable
        }),
      )
    }
    None => fail("expected visual selection")
  }
  match select_component(doc, "collision:base_link:0") {
    Some(detail) => {
      assert_eq(detail.kind, "collision")
      assert_eq(detail.commands.length(), 3)
      assert_true(detail.commands.contains("update-collision-origin"))
      assert_true(detail.commands.contains("update-collision-geometry"))
      assert_true(detail.commands.contains("remove-collision"))
      assert_true(
        detail.fields.any(fn(item) {
          item.name == "size" && item.value == "1 2 3" && item.editable
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
  match select_component(doc, "extension:comment:0") {
    Some(detail) => {
      assert_eq(detail.kind, "extension")
      assert_eq(detail.commands.length(), 1)
      assert_true(detail.commands.contains("update-extension-raw"))
      assert_true(
        detail.fields.any(fn(item) {
          item.name == "source" &&
          item.value.contains("preserve this comment") &&
          item.editable
        }),
      )
    }
    None => fail("expected comment extension selection")
  }
  assert_eq(select_component(doc, "missing") is None, true)
}

///|
test "urdf editor projects opaque extension nodes" {
  let source =
    #|<robot name="extension_bot">
    #|  <link name="base">
    #|    <vendor:payload enabled="true"/>
    #|  </link>
    #|  <link name="tool"/>
    #|  <joint name="j" type="fixed">
    #|    <parent link="base"/>
    #|    <child link="tool"/>
    #|  </joint>
    #|  <transmission name="drive">
    #|    <type>demo</type>
    #|  </transmission>
    #|  <gazebo reference="base">
    #|    <plugin name="sim" filename="libsim.so"/>
    #|  </gazebo>
    #|</robot>
  let doc = parse_document(source)
  assert_eq(doc.extensions.length(), 3)
  assert_true(
    doc.extensions.any(fn(item) {
      item.kind == "unknown" && item.parent_id == "link:base"
    }),
  )
  assert_true(
    doc.extensions.any(fn(item) {
      item.kind == "transmission" && item.label == "drive"
    }),
  )
  assert_true(
    doc.extensions.any(fn(item) {
      item.kind == "gazebo" && item.label == "base"
    }),
  )
  assert_true(doc.issues.any(fn(item) { item.code == "extension-preserved" }))
  let rows = component_tree(doc)
  assert_true(
    rows.any(fn(row) { row.kind == "extension" && row.parent_id == "link:base" }),
  )
  let extension = doc.extensions[0]
  match select_component(doc, extension.node_id) {
    Some(detail) => {
      assert_eq(detail.kind, "extension")
      assert_eq(detail.commands.length(), 2)
      assert_true(detail.commands.contains("update-extension-raw"))
      assert_true(detail.commands.contains("update-extension-attribute"))
      assert_true(detail.fields.any(fn(item) { item.name == "source" }))
      assert_true(detail.fields.any(fn(item) { item.name == "attribute" }))
    }
    None => fail("expected extension selection")
  }
  match select_component(doc, "extension:gazebo:2") {
    Some(detail) => {
      assert_eq(detail.kind, "extension")
      assert_true(detail.commands.contains("update-gazebo-plugin"))
      assert_true(
        detail.fields.any(fn(item) {
          item.name == "plugin name" && item.value == "sim" && item.editable
        }),
      )
      assert_true(
        detail.fields.any(fn(item) {
          item.name == "plugin filename" &&
          item.value == "libsim.so" &&
          item.command == "update-gazebo-plugin"
        }),
      )
    }
    None => fail("expected gazebo plugin extension selection")
  }
  match select_component(doc, "extension:transmission:1") {
    Some(detail) => {
      assert_eq(detail.kind, "extension")
      assert_true(detail.commands.contains("update-transmission"))
      assert_true(
        detail.fields.any(fn(item) {
          item.name == "transmission type" &&
          item.value == "demo" &&
          item.editable
        }),
      )
      assert_true(
        detail.fields.any(fn(item) {
          item.name == "transmission joint" &&
          item.command == "update-transmission"
        }),
      )
    }
    None => fail("expected transmission extension selection")
  }
}

///|
test "urdf editor updates opaque extension source" {
  let source =
    #|<robot name="extension_bot">
    #|  <link name="base">
    #|    <vendor:payload enabled="true"/>
    #|  </link>
    #|  <gazebo reference="base">
    #|    <plugin name="sim" filename="libsim.so"/>
    #|  </gazebo>
    #|</robot>
  let doc = parse_document(source)
  let mut gazebo : UrdfExtensionNode? = None
  for extension in doc.extensions {
    if extension.kind == "gazebo" {
      gazebo = Some(extension)
    }
  }
  let gazebo = match gazebo {
    Some(value) => value
    None => fail("expected gazebo extension")
  }
  match
    update_extension_raw(source, gazebo.node_id, {
      raw_source: (
        #|<gazebo reference="base">
        #|  <plugin name="physics" filename="libphysics.so"/>
        #|</gazebo>,
      ),
    }) {
    Ok(edit) => {
      assert_true(edit.changed)
      assert_eq(edit.command, "update-extension-raw")
      assert_eq(edit.target, gazebo.node_id)
      assert_true(edit.source.contains("name=\"physics\""))
      assert_true(edit.source.contains("<vendor:payload enabled=\"true\"/>"))
      let next = parse_document(edit.source)
      assert_true(
        next.extensions.any(fn(item) {
          item.kind == "gazebo" && item.label == "base"
        }),
      )
    }
    Err(error) => fail(error.message)
  }
}

///|
test "urdf editor updates extension open tag attributes" {
  let source =
    #|<robot name="extension_attr_bot">
    #|  <link name="base"/>
    #|  <gazebo reference="base">
    #|    <plugin name="sim" filename="libsim.so"/>
    #|  </gazebo>
    #|</robot>
  let doc = parse_document(source)
  let gazebo = doc.extensions[0]
  match
    update_extension_attribute(source, gazebo.node_id, {
      name: "reference",
      value: "base_link",
    }) {
    Ok(edit) => {
      assert_true(edit.changed)
      assert_eq(edit.command, "update-extension-attribute")
      assert_true(edit.source.contains("<gazebo reference=\"base_link\">"))
      assert_true(edit.source.contains("filename=\"libsim.so\""))
    }
    Err(error) => fail(error.message)
  }
}

///|
test "urdf editor adds and removes extension attributes" {
  let source =
    #|<robot name="extension_attr_bot">
    #|  <plugin name="sim" filename="libsim.so"/>
    #|</robot>
  let doc = parse_document(source)
  let plugin = doc.extensions[0]
  let added = match
    update_extension_attribute(source, plugin.node_id, {
      name: "topic",
      value: "arm & hand",
    }) {
    Ok(edit) => edit.source
    Err(error) => fail(error.message)
  }
  assert_true(added.contains("topic=\"arm &amp; hand\""))
  match
    update_extension_attribute(added, plugin.node_id, {
      name: "filename",
      value: "",
    }) {
    Ok(edit) => {
      assert_true(edit.changed)
      assert_false(edit.source.contains("filename=\"libsim.so\""))
      assert_true(edit.source.contains("topic=\"arm &amp; hand\""))
    }
    Err(error) => fail(error.message)
  }
}

///|
test "urdf editor rejects comment extension attribute edits" {
  let source =
    #|<robot name="extension_attr_bot">
    #|  <!-- vendor note -->
    #|</robot>
  let doc = parse_document(source)
  let comment = doc.extensions[0]
  match
    update_extension_attribute(source, comment.node_id, {
      name: "name",
      value: "note",
    }) {
    Ok(_) => fail("expected comment attribute rejection")
    Err(error) => assert_eq(error.code, "extension-attribute-unsupported")
  }
}

///|
test "urdf editor updates typed transmission fields" {
  let source =
    #|<robot name="transmission_bot">
    #|  <link name="base"/>
    #|  <link name="arm"/>
    #|  <joint name="shoulder_joint" type="revolute">
    #|    <parent link="base"/>
    #|    <child link="arm"/>
    #|  </joint>
    #|  <transmission name="shoulder_drive">
    #|    <type>old/type</type>
    #|    <joint name="old_joint"/>
    #|    <actuator name="old_motor">
    #|      <mechanicalReduction>1</mechanicalReduction>
    #|    </actuator>
    #|  </transmission>
    #|</robot>
  let doc = parse_document(source)
  match
    update_transmission(source, "extension:transmission:0", {
      transmission_type: Some("transmission_interface/SimpleTransmission"),
      joint_name: Some("shoulder_joint"),
      actuator_name: Some("shoulder_motor"),
      mechanical_reduction: Some(80.0),
    }) {
    Ok(edit) => {
      assert_true(edit.changed)
      assert_eq(edit.command, "update-transmission")
      assert_true(
        edit.source.contains(
          "<type>transmission_interface/SimpleTransmission</type>",
        ),
      )
      assert_true(edit.source.contains("<joint name=\"shoulder_joint\"/>"))
      assert_true(edit.source.contains("<actuator name=\"shoulder_motor\">"))
      assert_true(
        edit.source.contains("<mechanicalReduction>80</mechanicalReduction>"),
      )
      assert_eq(
        parse_document(edit.source).extensions.length(),
        doc.extensions.length(),
      )
    }
    Err(error) => fail(error.message)
  }
}

///|
test "urdf editor inserts missing typed transmission children" {
  let source =
    #|<robot name="transmission_bot">
    #|  <link name="base"/>
    #|  <link name="arm"/>
    #|  <joint name="shoulder_joint" type="fixed">
    #|    <parent link="base"/>
    #|    <child link="arm"/>
    #|  </joint>
    #|  <transmission name="shoulder_drive"/>
    #|</robot>
  match
    update_transmission(source, "extension:transmission:0", {
      transmission_type: Some("simple"),
      joint_name: Some("shoulder_joint"),
      actuator_name: Some("motor"),
      mechanical_reduction: Some(3.0),
    }) {
    Ok(edit) => {
      assert_true(
        edit.source.contains("<transmission name=\"shoulder_drive\">"),
      )
      assert_true(edit.source.contains("<type>simple</type>"))
      assert_true(edit.source.contains("<joint name=\"shoulder_joint\"/>"))
      assert_true(edit.source.contains("<actuator name=\"motor\">"))
      assert_true(
        edit.source.contains("<mechanicalReduction>3</mechanicalReduction>"),
      )
      assert_true(edit.source.contains("</transmission>"))
    }
    Err(error) => fail(error.message)
  }
}

///|
test "urdf editor rejects transmission edits on non-transmission extensions" {
  let source =
    #|<robot name="transmission_bot">
    #|  <gazebo reference="base"/>
    #|</robot>
  match
    update_transmission(source, "extension:gazebo:0", {
      transmission_type: Some("simple"),
      joint_name: None,
      actuator_name: None,
      mechanical_reduction: None,
    }) {
    Ok(_) => fail("expected transmission extension error")
    Err(error) => assert_eq(error.code, "transmission-extension-required")
  }
}

///|
test "urdf editor updates nested gazebo plugin fields" {
  let source =
    #|<robot name="gazebo_plugin_bot">
    #|  <gazebo reference="base">
    #|    <plugin name="sim" filename="libsim.so">
    #|      <topicName>/old</topicName>
    #|    </plugin>
    #|  </gazebo>
    #|</robot>
  match
    update_gazebo_plugin(source, "extension:gazebo:0", {
      plugin_name: Some("physics"),
      plugin_filename: Some("libphysics.so"),
      parameters: [{ name: "topicName", value: "/new & filtered" }],
    }) {
    Ok(edit) => {
      assert_true(edit.changed)
      assert_eq(edit.command, "update-gazebo-plugin")
      assert_true(
        edit.source.contains(
          "<plugin name=\"physics\" filename=\"libphysics.so\">",
        ),
      )
      assert_true(
        edit.source.contains("<topicName>/new &amp; filtered</topicName>"),
      )
      assert_true(edit.source.contains("<gazebo reference=\"base\">"))
    }
    Err(error) => fail(error.message)
  }
}

///|
test "urdf editor expands standalone plugin when adding parameters" {
  let source =
    #|<robot name="plugin_bot">
    #|  <plugin name="sim" filename="libsim.so"/>
    #|</robot>
  match
    update_gazebo_plugin(source, "extension:plugin:0", {
      plugin_name: Some("sim"),
      plugin_filename: Some("libsim.so"),
      parameters: [
        { name: "updateRate", value: "50" },
        { name: "topicName", value: "/sim" },
      ],
    }) {
    Ok(edit) => {
      assert_true(edit.changed)
      assert_true(
        edit.source.contains("<plugin name=\"sim\" filename=\"libsim.so\">"),
      )
      assert_true(edit.source.contains("<updateRate>50</updateRate>"))
      assert_true(edit.source.contains("<topicName>/sim</topicName>"))
      assert_true(edit.source.contains("</plugin>"))
    }
    Err(error) => fail(error.message)
  }
}

///|
test "urdf editor removes gazebo plugin parameters" {
  let source =
    #|<robot name="gazebo_plugin_bot">
    #|  <gazebo reference="base">
    #|    <plugin name="sim" filename="libsim.so">
    #|      <topicName>/old</topicName>
    #|    </plugin>
    #|  </gazebo>
    #|</robot>
  match
    update_gazebo_plugin(source, "extension:gazebo:0", {
      plugin_name: None,
      plugin_filename: None,
      parameters: [{ name: "topicName", value: "" }],
    }) {
    Ok(edit) => {
      assert_true(edit.changed)
      assert_false(edit.source.contains("<topicName>"))
      assert_true(edit.source.contains("filename=\"libsim.so\""))
    }
    Err(error) => fail(error.message)
  }
}

///|
test "urdf editor rejects gazebo plugin edits without plugin" {
  let source =
    #|<robot name="gazebo_plugin_bot">
    #|  <gazebo reference="base"/>
    #|</robot>
  match
    update_gazebo_plugin(source, "extension:gazebo:0", {
      plugin_name: Some("sim"),
      plugin_filename: Some("libsim.so"),
      parameters: [],
    }) {
    Ok(_) => fail("expected missing plugin error")
    Err(error) => assert_eq(error.code, "gazebo-plugin-missing")
  }
}

///|
test "urdf editor applies batched gazebo plugin parameter edits" {
  let source =
    #|<robot name="gazebo_plugin_bot">
    #|  <gazebo reference="base">
    #|    <plugin name="sim" filename="libsim.so">
    #|      <topicName>/old</topicName>
    #|      <legacy>drop</legacy>
    #|    </plugin>
    #|  </gazebo>
    #|</robot>
  match
    update_gazebo_plugin(source, "extension:gazebo:0", {
      plugin_name: Some("physics"),
      plugin_filename: None,
      parameters: [
        { name: "topicName", value: "/new & filtered" },
        { name: "updateRate", value: "50" },
        { name: "legacy", value: "" },
      ],
    }) {
    Ok(edit) => {
      assert_true(edit.changed)
      assert_true(
        edit.source.contains("<plugin name=\"physics\" filename=\"libsim.so\">"),
      )
      assert_true(
        edit.source.contains("<topicName>/new &amp; filtered</topicName>"),
      )
      assert_true(edit.source.contains("<updateRate>50</updateRate>"))
      assert_false(edit.source.contains("<legacy>"))
    }
    Err(error) => fail(error.message)
  }
}

///|
test "urdf editor exposes gazebo plugin schemas" {
  let schemas = gazebo_plugin_schemas()
  assert_eq(schemas.length(), 3)
  match gazebo_plugin_schema("gazebo_ros_diff_drive") {
    Some(schema) => {
      assert_eq(schema.plugin_name, "gazebo_ros_diff_drive")
      assert_eq(schema.plugin_filename, "libgazebo_ros_diff_drive.so")
      assert_true(schema.parameters.length() >= 8)
      assert_eq(schema.parameters[1].name, "commandTopic")
    }
    None => fail("expected diff drive schema")
  }
  match suggested_gazebo_plugin_schema("", "libgazebo_ros_control.so") {
    Some(schema) => assert_eq(schema.schema_id, "gazebo_ros_control")
    None => fail("expected ROS control schema")
  }
}

///|
test "urdf editor validates gazebo plugin schema parameters" {
  let issues = validate_gazebo_plugin_parameters("gazebo_ros_diff_drive", [
    { name: "commandTopic", value: "cmd_vel" },
    { name: "odometryTopic", value: "odom" },
    { name: "odometryFrame", value: "odom" },
    { name: "robotBaseFrame", value: "base_link" },
    { name: "updateRate", value: "fast" },
    { name: "publishOdom", value: "maybe" },
    { name: "extraTag", value: "value" },
  ])
  assert_eq(issues.length(), 5)
  assert_eq(issues[0].code, "plugin-schema-number-invalid")
  assert_eq(issues[0].parameter_name, "updateRate")
  assert_eq(issues[1].code, "plugin-schema-required-missing")
  assert_eq(issues[1].parameter_name, "wheelSeparation")
  assert_eq(issues[2].code, "plugin-schema-required-missing")
  assert_eq(issues[2].parameter_name, "wheelDiameter")
  assert_eq(issues[3].code, "plugin-schema-bool-invalid")
  assert_eq(issues[3].parameter_name, "publishOdom")
  assert_eq(issues[4].code, "plugin-schema-unknown-parameter")
  assert_eq(issues[4].parameter_name, "extraTag")
}

///|
test "urdf editor rejects extension source that changes tag kind" {
  let source =
    #|<robot name="extension_bot">
    #|  <gazebo reference="base"/>
    #|</robot>
  let doc = parse_document(source)
  let extension = doc.extensions[0]
  match
    update_extension_raw(source, extension.node_id, {
      raw_source: "<transmission name=\"drive\"/>",
    }) {
    Ok(_) => fail("expected extension tag change rejection")
    Err(error) => {
      assert_eq(error.code, "extension-source-kind-changed")
      assert_eq(error.target, extension.node_id)
    }
  }
}

///|
test "urdf editor adds links before robot close" {
  let source =
    #|<robot name="add_link_bot">
    #|  <link name="base"/>
    #|</robot>
  match add_link(source, { name: "tool" }) {
    Ok(edit) => {
      assert_true(edit.changed)
      assert_eq(edit.command, "add-link")
      assert_eq(edit.target, "tool")
      assert_true(edit.source.contains("<link name=\"base\"/>"))
      assert_true(edit.source.contains("<link name=\"tool\"/>"))
      let doc = parse_document(edit.source)
      assert_eq(doc.links.length(), 2)
      assert_true(find_link(doc, "tool") is Some(_))
    }
    Err(error) => fail(error.message)
  }
}

///|
test "urdf editor adds joints before robot close" {
  let source =
    #|<robot name="add_joint_bot">
    #|  <link name="base"/>
    #|  <link name="tool"/>
    #|</robot>
  match
    add_joint(source, {
      name: "tool_fixed",
      joint_type: "fixed",
      parent_link: "base",
      child_link: "tool",
      origin: Some({ xyz: "0 0 1", rpy: "0 0 0" }),
      axis: None,
      limit: None,
    }) {
    Ok(edit) => {
      assert_true(edit.changed)
      assert_eq(edit.command, "add-joint")
      assert_eq(edit.target, "tool_fixed")
      assert_true(
        edit.source.contains("<joint name=\"tool_fixed\" type=\"fixed\">"),
      )
      assert_true(edit.source.contains("<parent link=\"base\"/>"))
      assert_true(edit.source.contains("<child link=\"tool\"/>"))
      assert_true(edit.source.contains("<origin xyz=\"0 0 1\" rpy=\"0 0 0\"/>"))
      let doc = parse_document(edit.source)
      assert_eq(doc.joints.length(), 1)
      assert_true(find_joint(doc, "tool_fixed") is Some(_))
    }
    Err(error) => fail(error.message)
  }
}

///|
test "urdf editor adds visual to self-closing link" {
  let source =
    #|<robot name="add_visual_bot">
    #|  <link name="base"/>
    #|</robot>
  match
    add_visual(source, {
      link_name: "base",
      origin: Some({ xyz: "0 0 1", rpy: "0 0 0" }),
      geometry: {
        kind: "box",
        mesh_filename: None,
        mesh_scale: None,
        size: Some("1 2 3"),
        radius: None,
        length: None,
      },
    }) {
    Ok(edit) => {
      assert_true(edit.changed)
      assert_eq(edit.command, "add-visual")
      assert_eq(edit.target, "base:0")
      assert_true(edit.source.contains("<link name=\"base\">"))
      assert_true(edit.source.contains("<visual>"))
      assert_true(edit.source.contains("<origin xyz=\"0 0 1\" rpy=\"0 0 0\"/>"))
      assert_true(edit.source.contains("<box size=\"1 2 3\"/>"))
      let doc = parse_document(edit.source)
      assert_eq(doc.visuals.length(), 1)
      assert_eq(doc.visuals[0].node_id, "visual:base:0")
      assert_eq(doc.visuals[0].geometry_kind, "box")
    }
    Err(error) => fail(error.message)
  }
}

///|
test "urdf editor adds collision to self-closing link" {
  let source =
    #|<robot name="add_collision_bot">
    #|  <link name="base"/>
    #|</robot>
  match
    add_collision(source, {
      link_name: "base",
      origin: None,
      geometry: {
        kind: "sphere",
        mesh_filename: None,
        mesh_scale: None,
        size: None,
        radius: Some(0.25),
        length: None,
      },
    }) {
    Ok(edit) => {
      assert_true(edit.changed)
      assert_eq(edit.command, "add-collision")
      assert_eq(edit.target, "base:0")
      assert_true(edit.source.contains("<link name=\"base\">"))
      assert_true(edit.source.contains("<collision>"))
      assert_true(edit.source.contains("<sphere radius=\"0.25\"/>"))
      let doc = parse_document(edit.source)
      assert_eq(doc.collisions.length(), 1)
      assert_eq(doc.collisions[0].node_id, "collision:base:0")
      assert_eq(doc.collisions[0].geometry_kind, "sphere")
    }
    Err(error) => fail(error.message)
  }
}

///|
test "urdf editor removes visual and collision blocks" {
  let source =
    #|<robot name="remove_vc_bot">
    #|  <link name="base">
    #|    <visual><geometry><box size="1 1 1"/></geometry></visual>
    #|    <collision><geometry><sphere radius="0.5"/></geometry></collision>
    #|  </link>
    #|</robot>
  let without_visual = match remove_visual(source, "base", 0) {
    Ok(value) => value
    Err(error) => fail(error.message)
  }
  assert_true(without_visual.changed)
  assert_false(without_visual.source.contains("<visual>"))
  let after_visual = parse_document(without_visual.source)
  assert_eq(after_visual.visuals.length(), 0)
  assert_eq(after_visual.collisions.length(), 1)
  let without_collision = match
    remove_collision(without_visual.source, "base", 0) {
    Ok(value) => value
    Err(error) => fail(error.message)
  }
  assert_true(without_collision.changed)
  assert_false(without_collision.source.contains("<collision>"))
  let doc = parse_document(without_collision.source)
  assert_eq(doc.visuals.length(), 0)
  assert_eq(doc.collisions.length(), 0)
  assert_eq(doc.links.length(), 1)
}

///|
test "urdf editor rejects invalid visual creation" {
  let source =
    #|<robot name="reject_visual_bot">
    #|  <link name="base"/>
    #|</robot>
  match
    add_visual(source, {
      link_name: "missing",
      origin: None,
      geometry: {
        kind: "box",
        mesh_filename: None,
        mesh_scale: None,
        size: Some("1 2 3"),
        radius: None,
        length: None,
      },
    }) {
    Ok(_) => fail("expected missing link rejection")
    Err(error) => assert_eq(error.code, "link-not-found")
  }
  match
    add_visual(source, {
      link_name: "base",
      origin: None,
      geometry: {
        kind: "capsule",
        mesh_filename: None,
        mesh_scale: None,
        size: None,
        radius: None,
        length: None,
      },
    }) {
    Ok(_) => fail("expected invalid geometry rejection")
    Err(error) => assert_eq(error.code, "geometry-invalid")
  }
}

///|
test "urdf editor rejects added joint with unknown child link" {
  let source =
    #|<robot name="add_joint_bot">
    #|  <link name="base"/>
    #|</robot>
  match
    add_joint(source, {
      name: "tool_fixed",
      joint_type: "fixed",
      parent_link: "base",
      child_link: "tool",
      origin: None,
      axis: None,
      limit: None,
    }) {
    Ok(_) => fail("expected unknown child link rejection")
    Err(error) => assert_eq(error.code, "joint-child-unknown")
  }
}

///|
test "urdf editor session retargets structural edits" {
  let source =
    #|<robot name="retarget_bot">
    #|  <link name="base"/>
    #|</robot>
  let session = start_session(source)
  let edit = match add_link(session.source, { name: "tool" }) {
    Ok(value) => value
    Err(error) => fail(error.message)
  }
  let next = push_session_edit(session, edit)
  assert_eq(next.selected_node_id, "link:tool")
  let visual_edit = match
    add_visual(next.source, {
      link_name: "base",
      origin: None,
      geometry: {
        kind: "box",
        mesh_filename: None,
        mesh_scale: None,
        size: Some("1 1 1"),
        radius: None,
        length: None,
      },
    }) {
    Ok(value) => value
    Err(error) => fail(error.message)
  }
  let after_visual = push_session_edit(next, visual_edit)
  assert_eq(after_visual.selected_node_id, "visual:base:0")
}

///|
test "urdf editor viewport targets map runtime items to editor nodes" {
  let link = viewport_link_target("base_link", 0, "root")
  assert_eq(link.node_id, "link:base_link")
  assert_eq(link.selection_type, "link")
  assert_eq(link.sub_type, "")
  assert_eq(link.object_index, -1)
  let joint = viewport_joint_target(
    "shoulder_joint", "revolute", "base_link", "arm_link", "within-limit",
  )
  assert_eq(joint.node_id, "joint:shoulder_joint")
  assert_eq(joint.selection_type, "joint")
  assert_eq(joint.link_name, "arm_link")
  let visual = viewport_visual_target("arm_link", 2, "mesh", "resolved")
  assert_eq(visual.node_id, "visual:arm_link:2")
  assert_eq(visual.selection_type, "link")
  assert_eq(visual.sub_type, "visual")
  assert_eq(visual.object_index, 2)
  let collision = viewport_collision_target("arm_link", 1, "box", "primitive")
  assert_eq(collision.node_id, "collision:arm_link:1")
  assert_eq(collision.sub_type, "collision")
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
test "urdf editor updates only the selected joint axis tag" {
  match update_joint_axis(fixture(), "shoulder_joint", { xyz: "1 0 0" }) {
    Ok(edit) => {
      assert_true(edit.changed)
      assert_true(edit.source.contains("<!-- preserve this comment -->"))
      assert_true(edit.source.contains("<axis xyz=\"1 0 0\"/>"))
      assert_true(
        edit.source.contains(
          "<limit lower=\"-1\" upper=\"1\" effort=\"20\" velocity=\"2\"/>",
        ),
      )
      let doc = parse_document(edit.source)
      assert_eq(doc.joints[0].axis, "1 0 0")
      assert_true(doc.joints[0].axis_node is Some(_))
    }
    Err(error) => fail(error.message)
  }
}

///|
test "urdf editor inserts missing joint axis before joint close" {
  let source =
    #|<robot name="insert_axis_bot">
    #|  <link name="a"/>
    #|  <link name="b"/>
    #|  <joint name="j" type="revolute">
    #|    <parent link="a"/>
    #|    <child link="b"/>
    #|  </joint>
    #|</robot>
  match update_joint_axis(source, "j", { xyz: "0 1 0" }) {
    Ok(edit) => {
      assert_true(edit.source.contains("<axis xyz=\"0 1 0\"/>"))
      let doc = parse_document(edit.source)
      assert_eq(doc.joints[0].axis, "0 1 0")
      assert_true(doc.joints[0].axis_node is Some(_))
    }
    Err(error) => fail(error.message)
  }
}

///|
test "urdf editor updates only the selected joint dynamics tag" {
  match
    update_joint_dynamics(fixture(), "shoulder_joint", {
      damping: Some(0.3),
      friction: Some(0.4),
    }) {
    Ok(edit) => {
      assert_eq(edit.command, "update-joint-dynamics")
      assert_true(edit.changed)
      assert_true(edit.source.contains("<!-- preserve this comment -->"))
      assert_true(
        edit.source.contains("<dynamics damping=\"0.3\" friction=\"0.4\"/>"),
      )
      assert_true(edit.source.contains("<axis xyz=\"0 0 1\"/>"))
      assert_true(
        edit.source.contains(
          "<limit lower=\"-1\" upper=\"1\" effort=\"20\" velocity=\"2\"/>",
        ),
      )
      let doc = parse_document(edit.source)
      match doc.joints[0].dynamics {
        Some(dynamics) => {
          assert_true(dynamics.damping is Some(0.3))
          assert_true(dynamics.friction is Some(0.4))
        }
        None => fail("expected dynamics")
      }
    }
    Err(error) => fail(error.message)
  }
}

///|
test "urdf editor inserts missing joint dynamics before joint close" {
  let source =
    #|<robot name="insert_dynamics_bot">
    #|  <link name="base"/>
    #|  <link name="tool"/>
    #|  <joint name="j" type="revolute">
    #|    <parent link="base"/>
    #|    <child link="tool"/>
    #|  </joint>
    #|</robot>
  match
    update_joint_dynamics(source, "j", { damping: Some(0.05), friction: None }) {
    Ok(edit) => {
      assert_true(edit.source.contains("<dynamics damping=\"0.05\"/>"))
      let doc = parse_document(edit.source)
      match doc.joints[0].dynamics {
        Some(dynamics) => {
          assert_true(dynamics.damping is Some(0.05))
          assert_true(dynamics.friction is None)
        }
        None => fail("expected dynamics")
      }
    }
    Err(error) => fail(error.message)
  }
}

///|
test "urdf editor updates only the selected joint mimic tag" {
  let source =
    #|<robot name="mimic_bot">
    #|  <link name="base"/>
    #|  <link name="arm"/>
    #|  <link name="finger"/>
    #|  <joint name="driver_joint" type="revolute">
    #|    <parent link="base"/>
    #|    <child link="arm"/>
    #|  </joint>
    #|  <joint name="finger_joint" type="revolute">
    #|    <parent link="arm"/>
    #|    <child link="finger"/>
    #|    <mimic joint="driver_joint" multiplier="1" offset="0"/>
    #|  </joint>
    #|</robot>
  match
    update_joint_mimic(source, "finger_joint", {
      target_joint: "driver_joint",
      multiplier: Some(-1.0),
      offset: Some(0.25),
    }) {
    Ok(edit) => {
      assert_eq(edit.command, "update-joint-mimic")
      assert_true(edit.changed)
      assert_true(
        edit.source.contains(
          "<mimic joint=\"driver_joint\" multiplier=\"-1\" offset=\"0.25\"/>",
        ),
      )
      assert_true(edit.source.contains("<joint name=\"driver_joint\""))
      let doc = parse_document(edit.source)
      match doc.joints[1].mimic {
        Some(mimic) => {
          assert_eq(mimic.target_joint, "driver_joint")
          assert_true(mimic.multiplier is Some(-1.0))
          assert_true(mimic.offset is Some(0.25))
        }
        None => fail("expected mimic")
      }
    }
    Err(error) => fail(error.message)
  }
}

///|
test "urdf editor inserts missing joint mimic before joint close" {
  let source =
    #|<robot name="insert_mimic_bot">
    #|  <link name="base"/>
    #|  <link name="arm"/>
    #|  <link name="finger"/>
    #|  <joint name="driver_joint" type="revolute">
    #|    <parent link="base"/>
    #|    <child link="arm"/>
    #|  </joint>
    #|  <joint name="finger_joint" type="revolute">
    #|    <parent link="arm"/>
    #|    <child link="finger"/>
    #|  </joint>
    #|</robot>
  match
    update_joint_mimic(source, "finger_joint", {
      target_joint: "driver_joint",
      multiplier: Some(0.5),
      offset: None,
    }) {
    Ok(edit) => {
      assert_true(
        edit.source.contains(
          "<mimic joint=\"driver_joint\" multiplier=\"0.5\"/>",
        ),
      )
      let doc = parse_document(edit.source)
      match doc.joints[1].mimic {
        Some(mimic) => {
          assert_eq(mimic.target_joint, "driver_joint")
          assert_true(mimic.multiplier is Some(0.5))
          assert_true(mimic.offset is None)
        }
        None => fail("expected mimic")
      }
    }
    Err(error) => fail(error.message)
  }
}

///|
test "urdf editor rejects mimic target that is not declared" {
  match
    update_joint_mimic(fixture(), "shoulder_joint", {
      target_joint: "missing_joint",
      multiplier: None,
      offset: None,
    }) {
    Ok(_) => fail("expected missing mimic target")
    Err(error) => assert_eq(error.code, "joint-mimic-target-not-found")
  }
}

///|
test "urdf editor updates only the selected joint calibration tag" {
  match
    update_joint_calibration(fixture(), "shoulder_joint", {
      rising: Some(0.02),
      falling: Some(-0.02),
    }) {
    Ok(edit) => {
      assert_eq(edit.command, "update-joint-calibration")
      assert_true(edit.changed)
      assert_true(edit.source.contains("<!-- preserve this comment -->"))
      assert_true(
        edit.source.contains("<calibration rising=\"0.02\" falling=\"-0.02\"/>"),
      )
      assert_true(
        edit.source.contains(
          "<safety_controller soft_lower_limit=\"-0.8\" soft_upper_limit=\"0.8\" k_position=\"10\" k_velocity=\"2\"/>",
        ),
      )
      let doc = parse_document(edit.source)
      match doc.joints[0].calibration {
        Some(calibration) => {
          assert_true(calibration.rising is Some(0.02))
          assert_true(calibration.falling is Some(-0.02))
        }
        None => fail("expected calibration")
      }
    }
    Err(error) => fail(error.message)
  }
}

///|
test "urdf editor inserts missing joint calibration before joint close" {
  let source =
    #|<robot name="insert_calibration_bot">
    #|  <link name="base"/>
    #|  <link name="tool"/>
    #|  <joint name="j" type="revolute">
    #|    <parent link="base"/>
    #|    <child link="tool"/>
    #|  </joint>
    #|</robot>
  match
    update_joint_calibration(source, "j", { rising: Some(0.03), falling: None }) {
    Ok(edit) => {
      assert_true(edit.source.contains("<calibration rising=\"0.03\"/>"))
      let doc = parse_document(edit.source)
      match doc.joints[0].calibration {
        Some(calibration) => {
          assert_true(calibration.rising is Some(0.03))
          assert_true(calibration.falling is None)
        }
        None => fail("expected calibration")
      }
    }
    Err(error) => fail(error.message)
  }
}

///|
test "urdf editor rejects empty joint calibration patch" {
  match
    update_joint_calibration(fixture(), "shoulder_joint", {
      rising: None,
      falling: None,
    }) {
    Ok(_) => fail("expected missing calibration fields")
    Err(error) => assert_eq(error.code, "joint-calibration-required")
  }
}

///|
test "urdf editor updates only the selected joint safety controller tag" {
  match
    update_joint_safety_controller(fixture(), "shoulder_joint", {
      soft_lower_limit: Some(-0.7),
      soft_upper_limit: Some(0.7),
      k_position: Some(12.0),
      k_velocity: Some(3.0),
    }) {
    Ok(edit) => {
      assert_eq(edit.command, "update-joint-safety-controller")
      assert_true(edit.changed)
      assert_true(edit.source.contains("<!-- preserve this comment -->"))
      assert_true(
        edit.source.contains(
          "<safety_controller soft_lower_limit=\"-0.7\" soft_upper_limit=\"0.7\" k_position=\"12\" k_velocity=\"3\"/>",
        ),
      )
      assert_true(
        edit.source.contains("<dynamics damping=\"0.1\" friction=\"0.2\"/>"),
      )
      let doc = parse_document(edit.source)
      match doc.joints[0].safety_controller {
        Some(safety_controller) => {
          assert_true(safety_controller.soft_lower_limit is Some(-0.7))
          assert_true(safety_controller.soft_upper_limit is Some(0.7))
          assert_true(safety_controller.k_position is Some(12.0))
          assert_true(safety_controller.k_velocity is Some(3.0))
        }
        None => fail("expected safety controller")
      }
    }
    Err(error) => fail(error.message)
  }
}

///|
test "urdf editor inserts missing joint safety controller before joint close" {
  let source =
    #|<robot name="insert_safety_bot">
    #|  <link name="base"/>
    #|  <link name="tool"/>
    #|  <joint name="j" type="revolute">
    #|    <parent link="base"/>
    #|    <child link="tool"/>
    #|  </joint>
    #|</robot>
  match
    update_joint_safety_controller(source, "j", {
      soft_lower_limit: Some(-0.5),
      soft_upper_limit: Some(0.5),
      k_position: None,
      k_velocity: Some(1.5),
    }) {
    Ok(edit) => {
      assert_true(
        edit.source.contains(
          "<safety_controller soft_lower_limit=\"-0.5\" soft_upper_limit=\"0.5\" k_velocity=\"1.5\"/>",
        ),
      )
      let doc = parse_document(edit.source)
      match doc.joints[0].safety_controller {
        Some(safety_controller) => {
          assert_true(safety_controller.soft_lower_limit is Some(-0.5))
          assert_true(safety_controller.soft_upper_limit is Some(0.5))
          assert_true(safety_controller.k_position is None)
          assert_true(safety_controller.k_velocity is Some(1.5))
        }
        None => fail("expected safety controller")
      }
    }
    Err(error) => fail(error.message)
  }
}

///|
test "urdf editor rejects reversed joint safety controller soft limits" {
  match
    update_joint_safety_controller(fixture(), "shoulder_joint", {
      soft_lower_limit: Some(1.0),
      soft_upper_limit: Some(-1.0),
      k_position: None,
      k_velocity: None,
    }) {
    Ok(_) => fail("expected invalid safety controller")
    Err(error) => assert_eq(error.code, "joint-safety-controller-order")
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
test "urdf editor renames link and updates joint topology references" {
  match rename_link(fixture(), "base_link", "body_link") {
    Ok(edit) => {
      assert_true(edit.changed)
      assert_true(edit.source.contains("<link name=\"body_link\">"))
      assert_true(edit.source.contains("<parent link=\"body_link\"/>"))
      let doc = parse_document(edit.source)
      assert_true(find_link(doc, "body_link") is Some(_))
      assert_true(find_link(doc, "base_link") is None)
      assert_eq(doc.joints[0].parent_link, "body_link")
      assert_eq(doc.issues.length(), 0)
    }
    Err(error) => fail(error.message)
  }
}

///|
test "urdf editor renames joint declaration" {
  match rename_joint(fixture(), "shoulder_joint", "arm_joint") {
    Ok(edit) => {
      assert_true(edit.changed)
      assert_true(edit.source.contains("<joint name=\"arm_joint\""))
      let doc = parse_document(edit.source)
      assert_true(find_joint(doc, "arm_joint") is Some(_))
      assert_true(find_joint(doc, "shoulder_joint") is None)
      assert_eq(doc.issues.length(), 0)
    }
    Err(error) => fail(error.message)
  }
}

///|
test "urdf editor rejects duplicate link rename" {
  match rename_link(fixture(), "base_link", "arm_link") {
    Ok(_) => fail("expected duplicate link rename to fail")
    Err(error) => assert_eq(error.code, "duplicate-link")
  }
}

///|
test "urdf editor session tracks source history and rename selection" {
  let session = start_session(fixture(), selected_node_id="link:base_link")
  assert_eq(session.selected_node_id, "link:base_link")
  assert_false(session.can_undo)
  assert_false(session.can_redo)
  let edit = match rename_link(session.source, "base_link", "body_link") {
    Ok(value) => value
    Err(error) => fail(error.message)
  }
  let edited = push_session_edit(session, edit)
  assert_eq(edited.selected_node_id, "link:body_link")
  assert_true(edited.dirty)
  assert_true(edited.diff.changed)
  assert_true(edited.diff.summary.contains("changed at byte"))
  assert_true(edited.diff.hunks.length() > 0)
  assert_true(edited.diff.hunks[0].before_text.contains("base_link"))
  assert_true(edited.diff.hunks[0].after_text.contains("body_link"))
  assert_eq(edited.history.length(), 2)
  assert_eq(edited.history[0].lane, "past")
  assert_eq(edited.history[1].lane, "present")
  assert_true(edited.history[1].current)
  assert_eq(edited.past_count, 1)
  assert_eq(edited.future_count, 0)
  assert_true(edited.can_undo)
  assert_false(edited.can_redo)
  assert_true(edited.source.contains("<link name=\"body_link\">"))
  match undo_session(edited) {
    Some(previous) => {
      assert_eq(previous.selected_node_id, "link:base_link")
      assert_false(previous.dirty)
      assert_true(previous.source.contains("<link name=\"base_link\">"))
      assert_eq(previous.past_count, 0)
      assert_eq(previous.future_count, 1)
      assert_false(previous.can_undo)
      assert_true(previous.can_redo)
      match redo_session(previous) {
        Some(redone) => {
          assert_eq(redone.selected_node_id, "link:body_link")
          assert_true(redone.dirty)
          assert_true(redone.source.contains("<link name=\"body_link\">"))
          assert_eq(redone.past_count, 1)
          assert_eq(redone.future_count, 0)
          let committed = commit_session(redone)
          assert_false(committed.dirty)
          assert_eq(committed.baseline_source, redone.source)
        }
        None => fail("expected redo session")
      }
    }
    None => fail("expected undo session")
  }
}

///|
test "urdf editor session reports separated source diff hunks" {
  let before = fixture()
  let after = before
    .replace(
      old="<color rgba=\"0.1 0.2 0.3 1\"/>",
      new="<color rgba=\"0.9 0.2 0.3 1\"/>",
    )
    .replace(
      old="<limit lower=\"-1\" upper=\"1\" effort=\"20\" velocity=\"2\"/>",
      new="<limit lower=\"-2\" upper=\"2\" effort=\"20\" velocity=\"2\"/>",
    )
  let edit : UrdfEditResult = {
    changed: true,
    command: "multi-field-preview",
    target: "review",
    source: after,
    message: "previewed separated changes",
    issues: [],
  }
  let edited = push_session_edit(start_session(before), edit)
  assert_eq(edited.diff.hunks.length(), 2)
  assert_true(edited.diff.hunks[0].before_text.contains("0.1 0.2 0.3 1"))
  assert_true(edited.diff.hunks[0].after_text.contains("0.9 0.2 0.3 1"))
  assert_true(edited.diff.hunks[1].before_text.contains("lower=\"-1\""))
  assert_true(edited.diff.hunks[1].after_text.contains("lower=\"-2\""))
}

///|
test "urdf editor session keeps no-op edits out of undo history" {
  let session = start_session(
    fixture(),
    selected_node_id="joint:shoulder_joint",
  )
  let edit = match
    rename_joint(session.source, "shoulder_joint", "shoulder_joint") {
    Ok(value) => value
    Err(error) => fail(error.message)
  }
  let edited = push_session_edit(session, edit)
  assert_false(edit.changed)
  assert_eq(edited.selected_node_id, "joint:shoulder_joint")
  assert_eq(edited.past_count, 0)
  assert_eq(edited.future_count, 0)
  assert_false(edited.can_undo)
  assert_false(edited.can_redo)
  assert_true(undo_session(edited) is None)
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
test "urdf editor updates visual geometry primitive while preserving origin and material" {
  match
    update_visual_geometry(fixture(), "base_link", 0, {
      kind: "box",
      mesh_filename: None,
      mesh_scale: None,
      size: Some("0.5 0.6 0.7"),
      radius: None,
      length: None,
    }) {
    Ok(edit) => {
      assert_true(edit.changed)
      assert_true(edit.source.contains("<box size=\"0.5 0.6 0.7\"/>"))
      assert_true(edit.source.contains("<origin xyz=\"0 0 0\" rpy=\"0 0 0\"/>"))
      assert_true(edit.source.contains("<material name=\"paint\"/>"))
      let doc = parse_document(edit.source)
      assert_eq(doc.visuals[0].geometry_kind, "box")
      assert_eq(doc.visuals[0].size, "0.5 0.6 0.7")
      assert_eq(doc.issues.length(), 0)
    }
    Err(error) => fail(error.message)
  }
}

///|
test "urdf editor updates collision geometry primitive" {
  match
    update_collision_geometry(fixture(), "base_link", 0, {
      kind: "cylinder",
      mesh_filename: None,
      mesh_scale: None,
      size: None,
      radius: Some(0.25),
      length: Some(0.8),
    }) {
    Ok(edit) => {
      assert_true(edit.changed)
      assert_true(
        edit.source.contains("<cylinder radius=\"0.25\" length=\"0.8\"/>"),
      )
      let doc = parse_document(edit.source)
      assert_eq(doc.collisions[0].geometry_kind, "cylinder")
      assert_true(doc.collisions[0].radius is Some(0.25))
      assert_true(doc.collisions[0].length is Some(0.8))
    }
    Err(error) => fail(error.message)
  }
}

///|
test "urdf editor inserts missing visual geometry block" {
  let source =
    #|<robot name="insert_geometry_bot">
    #|  <link name="base">
    #|    <visual>
    #|      <origin xyz="0 0 0" rpy="0 0 0"/>
    #|    </visual>
    #|  </link>
    #|</robot>
  match
    update_visual_geometry(source, "base", 0, {
      kind: "mesh",
      mesh_filename: Some("package://demo/meshes/base.stl"),
      mesh_scale: Some("1 1 1"),
      size: None,
      radius: None,
      length: None,
    }) {
    Ok(edit) => {
      assert_true(edit.source.contains("<geometry>"))
      assert_true(
        edit.source.contains(
          "<mesh filename=\"package://demo/meshes/base.stl\" scale=\"1 1 1\"/>",
        ),
      )
      let doc = parse_document(edit.source)
      assert_eq(doc.visuals[0].geometry_kind, "mesh")
      assert_eq(doc.visuals[0].mesh_filename, "package://demo/meshes/base.stl")
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
