///|
// Synthetic protocol regression only; this does not execute or certify CUDA.
async test "stream-v2 protocol preserves v1 warm reset semantics and rejects corruption before writes" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="moonrobo-protocol-v2-")
    let invalid_root = @fs.tmpdir(prefix="moonrobo-protocol-v2-overflow-")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    group.add_defer(() => @fs.rmdir(invalid_root, recursive=true))
    let device = ContractDevice::new()
    let env = contract_env(device)
    env.reset(frames=[3, 3])
    ignore(env.step(Array::makei(2, _ => Array::make(29, 0.1))))
    let legacy = env.snapshot()
    let saved = env.write_snapshot_v2(root)
    let target_device = ContractDevice::new()
    let target = contract_env(target_device)
    assert_false(target.restore_v2(root, saved))
    ignore(env.restore(legacy))
    assert_eq(target.snapshot().to_json(), env.snapshot().to_json())
    assert_eq(target.frames, env.frames)
    assert_eq(target.previous, env.previous)
    assert_eq(target_device.mu, device.mu)
    assert_eq(target_device.com, device.com)
    let before = target.snapshot().to_json()
    let resets = target_device.resets.length()
    let contexts = target_device.contexts.length()
    // Correct SHA and finite stored values are insufficient: the original
    // probability formula must be usable before any context/reset side effect.
    env.sampler.restore([-1.0e308], [1.0], [0])
    let overflowing = env.write_snapshot_v2(invalid_root)
    try target.restore_v2(invalid_root, overflowing) catch {
      _ => ()
    } noraise {
      _ => fail("overflowing sampler probabilities accepted")
    }
    assert_eq(target.snapshot().to_json(), before)
    assert_eq(target_device.resets.length(), resets)
    assert_eq(target_device.contexts.length(), contexts)
    let corrupt = @fs.open(
      root + "/" + saved.sampler.completed.file,
      mode=ReadWrite,
    )
    corrupt.write_at(b"\xff", position=0L)
    corrupt.close()
    try target.restore_v2(root, saved) catch {
      _ => ()
    } noraise {
      _ => fail("corrupt sampler accepted")
    }
    assert_eq(target.snapshot().to_json(), before)
    assert_eq(target_device.resets.length(), resets)
    assert_eq(target_device.contexts.length(), contexts)
  }
}
