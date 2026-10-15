///|
/// Publish the optional digital model as one directory, preserving saved models.
async fn install_bundled_robot_model(root : String, source : String) -> Unit {
  if !@afs.exists(source + "/urdf/e1_asm.urdf") {
    return
  }
  guard @afs.kind(root, follow_symlink=false) is Directory else {
    fail("RoboBook root must be a directory")
  }
  let target = root + "/e1_asm_251028"
  let existing = Some(@afs.kind(target, follow_symlink=false)) catch {
    _ => None
  }
  if existing is Some(kind) {
    guard kind is Directory else {
      fail("Bundled robot model destination must be a directory")
    }
    return
  }
  let staging = root + "/.e1-model-" + @async.now().to_string()
  copy_bundled_model_tree(source, staging)
  // NFS does not support renameat2(RENAME_NOREPLACE). A directory rename
  // cannot replace a symlink or a populated directory; recheck before the
  // portable POSIX operation so a saved model is never replaced.
  guard !@afs.exists(target) else {
    fail("Robot model destination changed during publication")
  }
  @afs.rename(staging, target)
}

///|
async fn copy_bundled_model_tree(source : String, target : String) -> Unit {
  guard @afs.kind(source, follow_symlink=false) is Directory else {
    fail("Bundled robot model must contain regular files and directories")
  }
  @afs.mkdir(target, permission=0o755)
  for name in @fsx.read_dir(source) {
    let from = source + "/" + name
    let to = target + "/" + name
    match @afs.kind(from, follow_symlink=false) {
      Directory => copy_bundled_model_tree(from, to)
      Regular =>
        @afs.write_file(
          to,
          @afs.read_file(from),
          create_mode=CreateNew,
          permission=0o644,
        )
      _ => fail("Bundled robot model must not contain links or devices")
    }
  }
}
