///|
fn loaded_book() -> @runtime.LoadedRoboBook {
  @runtime.load_robobook("examples/noetix-e1").unwrap()
}

///|
fn pipeline_result(
  book : @runtime.LoadedRoboBook,
  health : @core.BridgeHealth,
) -> @pipeline.PipelineResult {
  let intent = @pipeline.high_walk_intent(
    "intent-cockpit-walk",
    book.profile.id,
    @core.operator_requester("cockpit-test"),
    "0.10",
    "0.00",
    "1000",
  )
  @pipeline.evaluate_request(
    book.profile,
    health,
    intent,
    "receipt-cockpit-walk",
    0L,
  )
}

///|
fn telemetry(book : @runtime.LoadedRoboBook) -> @core.TelemetryFrame {
  {
    ..@core.empty_telemetry_frame(
      "frame-cockpit",
      book.profile.id,
      book.profile.bridge.id,
      0L,
    ),
    mode: "read-only",
    joints: book.profile.joints.map(fn(joint) {
      {
        name: joint.name,
        index: joint.index,
        position: 0.0,
        velocity: 0.0,
        torque: 0.0,
        error: None,
      }
    }),
    imu: Some({
      orientation: [1.0, 0.0, 0.0, 0.0],
      angular_velocity: [0.0, 0.0, 0.0],
      linear_acceleration: [0.0, 0.0, 9.8],
    }),
    operator_input: { "source": "test" },
  }
}

///|
fn sidecar(
  book : @runtime.LoadedRoboBook,
) -> @bridge_sidecar.BridgeSidecarStatus {
  @bridge_sidecar.status_for_spec(
    @bridge_sidecar.spec_for_profile(book.profile, book.root),
    false,
  )
}

///|
fn urdf_model(book : @runtime.LoadedRoboBook) -> @urdf.UrdfModel? {
  @runtime.read_urdf_model(book)
}

///|
test "cockpit projection composes first-screen state" {
  let book = loaded_book()
  let health = @core.bridge_ok(
    book.profile.bridge.id,
    book.profile.id,
    last_telemetry_age_ms=10,
  )
  let safety = pipeline_result(book, health)
  let receipts = [safety.receipt]
  let snapshot = @cockpit.snapshot(
    book,
    health,
    sidecar(book),
    telemetry(book),
    safety,
    receipts,
    urdf_model=urdf_model(book),
  )
  assert_eq(snapshot.robot.robot_id, "noetix-e1-lab-01")
  assert_eq(snapshot.product_status.service, "moonrobo")
  assert_eq(snapshot.product_status.status, "needs-foundation")
  assert_true(snapshot.robot.ready)
  assert_eq(snapshot.robot.joints, 24)
  assert_eq(snapshot.bridge.status, "ok")
  assert_false(snapshot.bridge.telemetry_stale)
  assert_eq(snapshot.sidecar.state, "missing-command")
  assert_false(snapshot.sidecar.ready_for_execution)
  assert_eq(snapshot.telemetry.joints, 24)
  assert_true(snapshot.telemetry.imu_available)
  assert_eq(snapshot.model_viewport.format, "urdf")
  assert_eq(snapshot.model_viewport.status, "ready")
  assert_eq(snapshot.model_viewport.mapped_joints, 24)
  assert_eq(snapshot.model_viewport.unmapped_joints, 0)
  assert_eq(snapshot.model_viewport.model_links, 25)
  assert_eq(snapshot.model_viewport.model_joints, 24)
  assert_eq(snapshot.model_viewport.visual_geometries, 6)
  assert_eq(snapshot.model_viewport.mesh_geometries, 1)
  assert_eq(snapshot.model_viewport.primitive_geometries, 5)
  assert_eq(snapshot.model_viewport.resolved_meshes, 1)
  assert_eq(snapshot.model_viewport.missing_meshes, 0)
  assert_eq(snapshot.model_viewport.external_meshes, 0)
  assert_eq(snapshot.model_viewport.visuals.length(), 6)
  assert_eq(snapshot.model_viewport.visuals[0].link_name, "base_link")
  assert_eq(snapshot.model_viewport.visuals[0].geometry_kind, "mesh")
  assert_eq(snapshot.model_viewport.visuals[0].asset_status, "resolved")
  assert_true(
    snapshot.model_viewport.visuals[0].resolved_mesh_path.contains(
      "model/meshes/base.obj",
    ),
  )
  assert_eq(snapshot.model_viewport.visuals[1].geometry_kind, "box")
  assert_eq(snapshot.model_viewport.visuals[1].asset_status, "primitive")
  assert_eq(snapshot.model_viewport.visual_instances.length(), 6)
  assert_eq(snapshot.model_viewport.visual_instances[0].link_name, "base_link")
  assert_eq(snapshot.model_viewport.visual_instances[0].link_status, "root")
  assert_eq(snapshot.model_viewport.visual_instances[1].z, 0.4)
  assert_eq(snapshot.model_viewport.root_link, "base_link")
  assert_eq(snapshot.model_viewport.simulated_links, 25)
  assert_eq(snapshot.model_viewport.model_mapped_joints, 24)
  assert_eq(snapshot.model_viewport.model_unmapped_joints, 0)
  assert_eq(snapshot.model_viewport.links[0].name, "base_link")
  assert_eq(snapshot.model_viewport.links[0].status, "root")
  assert_eq(snapshot.model_viewport.links[1].name, "torso_link")
  assert_eq(snapshot.model_viewport.links[1].parent_joint, "waist_1_joint")
  assert_eq(snapshot.model_viewport.links[1].depth, 1)
  assert_eq(snapshot.model_viewport.links[1].z, 0.32)
  assert_eq(snapshot.model_viewport.links[1].world_basis.xx, 1.0)
  assert_eq(snapshot.model_viewport.links[1].world_basis.yy, 1.0)
  assert_true(snapshot.model_viewport.links[1].transform.contains("q(0"))
  assert_eq(snapshot.model_viewport.joints[0].name, "arm_l1_joint")
  assert_eq(snapshot.model_viewport.joints[0].role, "arm")
  assert_true(snapshot.model_viewport.joints[0].mapped)
  assert_true(snapshot.model_viewport.joints[0].model_mapped)
  assert_eq(snapshot.model_viewport.joints[0].model_joint_type, "revolute")
  assert_eq(snapshot.model_viewport.joints[0].parent_link, "chest_link")
  assert_eq(snapshot.model_viewport.joints[0].limit_state, "ok")
  assert_true(snapshot.model_viewport.joints[0].limit_lower is Some(-1.8))
  assert_true(snapshot.model_viewport.joints[0].limit_upper is Some(1.8))
  assert_true(snapshot.model_viewport.joints[0].normalized_position is Some(_))
  assert_eq(snapshot.safety.next_action, "collect-dry-run")
  assert_eq(snapshot.latest_receipt.unwrap().receipt_id, "receipt-cockpit-walk")
}

///|
test "cockpit viewport resolves package meshes inside extracted URDF package" {
  let root = "/tmp/moonrobo-cockpit-package-mesh-test"
  if !@fsx.path_exists(root) {
    @fsx.create_dir(root) catch {
      _ => fail("failed to create package mesh root")
    }
  }
  let package_root = root + "/e1_asm_251028"
  if !@fsx.path_exists(package_root) {
    @fsx.create_dir(package_root) catch {
      _ => fail("failed to create package root")
    }
  }
  let urdf_dir = package_root + "/urdf"
  if !@fsx.path_exists(urdf_dir) {
    @fsx.create_dir(urdf_dir) catch {
      _ => fail("failed to create package urdf dir")
    }
  }
  let mesh_dir = package_root + "/meshes"
  if !@fsx.path_exists(mesh_dir) {
    @fsx.create_dir(mesh_dir) catch {
      _ => fail("failed to create package mesh dir")
    }
  }
  @fsx.write_string_to_file(
    mesh_dir + "/base_link.STL",
    "solid base\nendsolid base\n",
  ) catch {
    _ => fail("failed to write package mesh")
  }
  let base = loaded_book()
  let book = {
    ..base,
    root,
    profile: {
      ..base.profile,
      model: { ..base.profile.model, primary: "e1_asm_251028/urdf/e1_asm.urdf" },
    },
  }
  let model = @urdf.parse(
    (
      #|<robot name="e1_asm">
      #|  <link name="base_link">
      #|    <visual>
      #|      <geometry>
      #|        <mesh filename="package://e1_asm/meshes/base_link.STL"/>
      #|      </geometry>
      #|    </visual>
      #|  </link>
      #|</robot>
    ),
  )
  let viewport = @cockpit.model_viewport(
    book,
    telemetry(book),
    urdf_model=Some(model),
  )
  assert_eq(viewport.mesh_geometries, 1)
  assert_eq(viewport.resolved_meshes, 1)
  assert_eq(viewport.missing_meshes, 0)
  assert_eq(viewport.external_meshes, 0)
  assert_eq(viewport.visuals[0].asset_status, "resolved")
  assert_true(
    viewport.visuals[0].resolved_mesh_path.has_suffix(
      "e1_asm_251028/meshes/base_link.STL",
    ),
  )
}

///|
test "cockpit projection detects stale telemetry" {
  let book = loaded_book()
  let health = @core.bridge_ok(
    book.profile.bridge.id,
    book.profile.id,
    last_telemetry_age_ms=9999,
  )
  let safety = pipeline_result(book, health)
  let snapshot = @cockpit.snapshot(
    book,
    health,
    sidecar(book),
    telemetry(book),
    safety,
    [],
    urdf_model=urdf_model(book),
  )
  assert_true(snapshot.bridge.telemetry_stale)
  assert_eq(snapshot.product_status.next_route, "/api/moonrobo/ask")
  assert_true(snapshot.latest_receipt is None)
}

///|
test "cockpit viewport reports missing telemetry mappings" {
  let book = loaded_book()
  let health = @core.bridge_ok(
    book.profile.bridge.id,
    book.profile.id,
    last_telemetry_age_ms=10,
  )
  let safety = pipeline_result(book, health)
  let snapshot = @cockpit.snapshot(
    book,
    health,
    sidecar(book),
    @core.empty_telemetry_frame(
      "frame-empty",
      book.profile.id,
      book.profile.bridge.id,
      0L,
    ),
    safety,
    [],
    urdf_model=urdf_model(book),
  )
  assert_eq(snapshot.model_viewport.status, "diagnostic")
  assert_eq(snapshot.model_viewport.mapped_joints, 0)
  assert_eq(snapshot.model_viewport.unmapped_joints, 24)
  assert_eq(snapshot.model_viewport.model_mapped_joints, 24)
  assert_true(snapshot.model_viewport.issues[0].contains("declared joint"))
}

///|
test "cockpit viewport reports missing URDF mesh assets" {
  let book = loaded_book()
  let model = @urdf.parse(
    (
      #|<robot name="mesh_missing">
      #|  <link name="base_link">
      #|    <visual>
      #|      <geometry>
      #|        <mesh filename="meshes/missing.obj"/>
      #|      </geometry>
      #|    </visual>
      #|  </link>
      #|</robot>
    ),
  )
  let viewport = @cockpit.model_viewport(
    book,
    telemetry(book),
    urdf_model=Some(model),
  )
  assert_eq(viewport.mesh_geometries, 1)
  assert_eq(viewport.resolved_meshes, 0)
  assert_eq(viewport.missing_meshes, 1)
  assert_eq(viewport.visuals.length(), 1)
  assert_eq(viewport.visuals[0].asset_status, "missing")
  assert_eq(viewport.visual_instances.length(), 1)
  assert_eq(viewport.visual_instances[0].link_status, "root")
  assert_true(viewport.issues.any(fn(issue) { issue.contains("mesh asset") }))
  assert_eq(viewport.status, "diagnostic")
}

///|
test "cockpit viewport flags telemetry poses outside URDF limits" {
  let book = loaded_book()
  let health = @core.bridge_ok(
    book.profile.bridge.id,
    book.profile.id,
    last_telemetry_age_ms=10,
  )
  let safety = pipeline_result(book, health)
  let frame = telemetry(book)
  let limited_frame = {
    ..frame,
    joints: frame.joints.map(fn(joint) {
      if joint.name == "waist_1_joint" {
        { ..joint, position: 9.0 }
      } else {
        joint
      }
    }),
  }
  let snapshot = @cockpit.snapshot(
    book,
    health,
    sidecar(book),
    limited_frame,
    safety,
    [],
    urdf_model=urdf_model(book),
  )
  assert_eq(snapshot.model_viewport.status, "diagnostic")
  let waist = snapshot.model_viewport.joints[22]
  assert_eq(waist.name, "waist_1_joint")
  assert_eq(waist.limit_state, "above-limit")
  match waist.normalized_position {
    Some(value) => assert_true(value > 1.0)
    None => fail("expected normalized out-of-limit pose")
  }
  assert_true(
    snapshot.model_viewport.issues.any(fn(issue) {
      issue.contains("exceed URDF limits")
    }),
  )
}
