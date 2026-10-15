///|
async test "bundled digital model is published without replacing customer edits" {
  let root = @afs.tmpdir(prefix="moonrobo-bundled-model")
  let source = root + "/bundle"
  let workspace = root + "/workspace"
  @afs.mkdir(source)
  @afs.mkdir(source + "/urdf")
  @afs.mkdir(source + "/meshes")
  @afs.mkdir(workspace)
  @afs.write_file(
    source + "/urdf/e1_asm.urdf",
    "digital robot",
    create_mode=CreateNew,
  )
  @afs.write_file(
    source + "/meshes/base.STL",
    b"mesh-bytes",
    create_mode=CreateNew,
  )
  install_bundled_robot_model(workspace, source)
  let target = workspace + "/e1_asm_251028"
  assert_eq(@afs.read_file(target + "/meshes/base.STL").text(), "mesh-bytes")
  @afs.write_file(target + "/urdf/e1_asm.urdf", "customer edit")
  install_bundled_robot_model(workspace, source)
  assert_eq(
    @afs.read_file(target + "/urdf/e1_asm.urdf").text(),
    "customer edit",
  )
}

///|
async test "bundled model refuses a destination symlink" {
  let root = @afs.tmpdir(prefix="moonrobo-bundled-symlink")
  @afs.mkdir(root + "/bundle")
  @afs.mkdir(root + "/bundle/urdf")
  @afs.write_file(
    root + "/bundle/urdf/e1_asm.urdf",
    "digital robot",
    create_mode=CreateNew,
  )
  @afs.mkdir(root + "/workspace")
  @afs.mkdir(root + "/other")
  @afs.symlink(target=root + "/other", root + "/workspace/e1_asm_251028")
  let refused = try {
    install_bundled_robot_model(root + "/workspace", root + "/bundle")
    false
  } catch {
    _ => true
  }
  assert_true(refused)
  assert_false(@afs.exists(root + "/other/urdf/e1_asm.urdf"))
}
