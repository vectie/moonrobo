///|
test "stream-v2 episode counters are incrementable and reachable before physics" {
  let config = EnvironmentConfig::default()
  assert_true(valid_checkpoint_episode_step(0, config))
  assert_true(
    valid_checkpoint_episode_step(config.max_episode_steps - 1, config),
  )
  assert_false(valid_checkpoint_episode_step(config.max_episode_steps, config))
  assert_false(valid_checkpoint_episode_step(-1, config))
  assert_true(
    valid_checkpoint_episode_step(2147483646, { ..config, auto_reset: false, }),
  )
  assert_false(
    valid_checkpoint_episode_step(2147483647, { ..config, auto_reset: false, }),
  )
  assert_false(
    valid_checkpoint_episode_step(2147483647, { ..config, eval_mode: true, }),
  )
}

///|
/// Deferred real MuJoCo regression: no substitute adapter can certify exact
/// integration-state restore. Uses the existing explicit library/asset fixture.
async test "source real MuJoCo stream-v2 matches v1 and preserves next transition" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="moonrobo-physics-v2-")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let (library, scene, motion) = physics_test_fixture()
    let env = physics_test_env(library, scene, motion, count=1)
    env.reset(frames=[0])
    let actions = [Array::make(29, 0.05)]
    ignore(env.step(actions))
    let legacy = env.snapshot()
    let saved = env.write_snapshot_v2(root)
    let expected = env.step(actions)
    assert_true(env.restore_v2(root, saved))
    assert_eq(env.snapshot().to_json(), legacy.to_json())
    assert_eq(env.step(actions).to_json(), expected.to_json())
    let before = env.snapshot().to_json()
    let corrupt = @fs.open(
      root + "/" + saved.sampler.completed.file,
      mode=ReadWrite,
    )
    corrupt.write_at(b"\xff", position=0L)
    corrupt.close()
    try env.restore_v2(root, saved) catch {
      _ => ()
    } noraise {
      _ => fail("damaged physical checkpoint accepted")
    }
    assert_eq(env.snapshot().to_json(), before)
  }
}
