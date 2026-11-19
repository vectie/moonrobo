///|
test "vendor NPZ maps breadth-first joints and WXYZ root into the embedded contract" {
  let data : Map[String, @artifacts.NumericArray] = {
    "fps": { shape: [], dtype: "<f8", values: [50.0], },
    "joint_pos": {
      shape: [2, 24],
      dtype: "<f8",
      values: Array::makei(48, i => i.to_double()),
    },
    "body_pos_w": {
      shape: [2, 1, 3],
      dtype: "<f8",
      values: [1.0, 2.0, 0.8, 1.1, 2.1, 0.8],
    },
    "body_quat_w": {
      shape: [2, 1, 4],
      dtype: "<f8",
      values: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0],
    },
  }
  let (clip, fps) = vendor_motion(
    @artifacts.encode_npz(data),
    "fixture",
    profile(),
  )
  assert_eq(fps, 50.0)
  assert_eq(clip.rows[0][:7].to_owned(), [1.0, 2.0, 0.8, 0.0, 0.0, 0.0, 1.0])
  assert_eq(clip.rows[0][7:19].to_owned(), [
    0.0, 3.0, 6.0, 10.0, 14.0, 18.0, 1.0, 4.0, 7.0, 11.0, 15.0, 19.0,
  ])
  assert_eq(clip.rows[0][30:].to_owned(), Array::make(6, 0.0))
}

///|
async test "exported E1 actor matches checkpoint actions and rejects a corrupt receipt" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(tensor) &&
    @env.get_env_var("MOONROBO_E1_ACTOR") is Some(directory) &&
    @env.get_env_var("MOONROBO_E1_CHECKPOINT") is Some(pointer) else {
    println(
      "SKIP E1 archive integration: set tensor, E1 actor and checkpoint environment variables",
    )
    return
  }
  let (actor, metadata) = load_actor(directory, tensor)
  let (saved, generation) = open_checkpoint(pointer)
  let original = @inference.Actor::load_archive(
    @tensor.Backend::open(tensor),
    generation + "/policy.pt",
    @inference.ActorSpec::from_checkpoint(saved.learner),
  )
  let history = Array::makei(metadata.spec.hist, _ => Array::make(99, 0.1))
  let goal = Array::make(metadata.spec.goal_frames * 73, 0.2)
  let expected = metadata.identity.robot.project(
    original.forward(history, goal),
  )
  assert_eq(actor.forward_embedded(history, goal), expected)
  assert_eq(
    actor.forward(history, goal),
    expected[:metadata.identity.robot.joints.length()].to_owned(),
  )
  let temporary = @fs.tmpdir(prefix="e1-corrupt-archive")
  @fs.write_file(
    temporary + "/actor.pt",
    @fs.read_file(directory + "/actor.pt"),
    create_mode=CreateNew,
  )
  let corrupt = { ..metadata, archive_sha256: Array::make(64, "0").join(""), }
  @fs.write_file(
    temporary + "/actor.json",
    @utf8.encode(Json(corrupt).stringify()),
    create_mode=CreateNew,
  )
  assert_true((Some(load_actor(temporary, tensor)) catch { _ => None }) is None)
}

///|
test "damped retarget solve pivots and satisfies a known system" {
  let x = solve_ik([[0.0, 2.0], [3.0, 4.0]], [2.0, 7.0])
  assert_true((x[0] - 1.0).abs() < 1.0e-12)
  assert_true((x[1] - 1.0).abs() < 1.0e-12)
}
