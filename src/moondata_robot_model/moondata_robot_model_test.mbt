///|
fn ensure_dir(path : String) -> Unit {
  if !@fsx.path_exists(path) {
    @fsx.create_dir(path) catch {
      _ => ()
    }
  }
}

///|
test "robot model import copies URDF package into MoonData" {
  let root = "target/moondata-robot-model-import-root"
  let input = "target/moondata-robot-model-import-input"
  ensure_dir("target")
  ensure_dir(input)
  ensure_dir(input + "/meshes")
  ensure_dir(input + "/materials")
  @fsx.write_string_to_file(
    input + "/robot.urdf",
    "<robot name=\"fixture\"><link name=\"base_link\"/><joint name=\"hip_yaw\" type=\"revolute\"><parent link=\"base_link\"/><child link=\"torso\"/></joint><link name=\"torso\"/><mesh filename=\"package://fixture_pkg/meshes/base.stl\"/></robot>",
  ) catch {
    _ => fail("failed to write robot model import URDF")
  }
  @fsx.write_string_to_file(input + "/meshes/base.stl", "solid base\n") catch {
    _ => fail("failed to write robot model mesh")
  }
  @fsx.write_string_to_file(input + "/materials/base.json", "{}") catch {
    _ => fail("failed to write robot model material")
  }
  let result = match
    @moondata_robot_model.import_robot_model(
      @moondata_robot_model.robot_model_import_request(
        root,
        input,
        "robot-model-import-test",
        "robot-import-test",
        120L,
        package_name="fixture_pkg",
      ),
    ) {
    Ok(value) => value
    Err(error) => fail("robot model import failed: " + error.message)
  }
  assert_eq(result.model_id, "robot-model-import-test")
  assert_eq(result.asset_count, 3)
  assert_eq(result.mesh_count, 1)
  assert_eq(result.material_count, 1)
  assert_true(@fsx.path_exists(result.urdf_path))
  assert_true(
    @fsx.path_exists(
      root + "/media/robot_models/robot-model-import-test/meshes/base.stl",
    ),
  )
  let rewritten = @fsx.read_file_to_string(result.urdf_path) catch {
    _ => fail("failed to read rewritten URDF")
  }
  assert_true(
    rewritten.contains(
      "moondata://media/robot_models/robot-model-import-test/meshes/base.stl",
    ),
  )
  let loaded = match
    @moondata_store.read_robot_model(root, "robot-model-import-test") {
    Ok(value) => value
    Err(_) => fail("failed to read imported robot model")
  }
  assert_eq(loaded.urdf_ref.kind, "urdf")
  assert_eq(loaded.mesh_refs[0].kind, "stl")
  assert_eq(loaded.material_refs[0].kind, "material")
  assert_eq(loaded.link_names.length(), 2)
  assert_eq(loaded.joint_names[0], "hip_yaw")
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(_) => fail("failed to read robot model catalog")
  }
  assert_eq(catalog.entry_count, 1)
  assert_eq(catalog.entries[0].artifact_kind, "robot-model")
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=121L) {
    Ok(value) => value
    Err(_) => fail("failed to validate imported robot model")
  }
  assert_eq(report.status, "passed")
}
