///|
test "pre-step reuse preserves transitions resets sampler and evaluation exactly" {
  let a = ContractDevice::new()
  let b = ContractDevice::new()
  let baseline = contract_env(a)
  let candidate = contract_env(b, reuse_pre_step_state=true)
  for iteration in 0..<12 {
    if iteration == 5 {
      ignore(baseline.restore(baseline.snapshot()))
      ignore(candidate.restore(candidate.snapshot()))
    }
    if iteration == 8 {
      baseline.for_evaluation()
      candidate.for_evaluation()
    }
    let af = baseline.inspect()
    let bf = candidate.inspect()
    assert_eq(
      af.map(f => @aligned.flatten_state(f.state)),
      bf.map(f => @aligned.flatten_state(f.state)),
    )
    let ar = a.reads.length()
    let br = b.reads.length()
    let actions = Array::makei(2, i => {
      Array::make(29, 0.01 * (iteration + i).to_double())
    })
    let sa = baseline.step(actions)
    let sb = candidate.step(actions)
    assert_eq(a.reads.length() - ar, 2)
    assert_eq(b.reads.length() - br, 1)
    assert_eq(sa.transitions.to_json(), sb.transitions.to_json())
    assert_eq(sa.done, sb.done)
    assert_eq(sa.timeout, sb.timeout)
    assert_eq(sa.active, sb.active)
    assert_eq(sa.reset_ids, sb.reset_ids)
    assert_eq(baseline.snapshot().to_json(), candidate.snapshot().to_json())
  }
}

///|
test "inspection cache is private single-use and invalidated on reset and errors" {
  let device = ContractDevice::new()
  let env = contract_env(device, reuse_pre_step_state=true)
  env.reset(frames=[0, 0])
  let frames = env.inspect()
  let expected = @aligned.flatten_state(frames[0].state)
  frames[0].state.p[0] = 123.0
  frames[0].xi[0] = 987.0
  frames[0].previous[0] = 987.0
  let actions = Array::makei(2, _ => Array::make(29, 0.0))
  assert_eq(env.step(actions).transitions[0].s, expected)
  assert_true(env.pending_inspection is None)
  let reads = device.reads.length()
  ignore(env.step(actions))
  assert_eq(device.reads.length() - reads, 2)
  ignore(env.inspect())
  env.reset(frames=[0, 0])
  assert_true(env.pending_inspection is None)
  ignore(env.inspect())
  try env.step([]) catch {
    _ => ()
  } noraise {
    _ => fail("invalid actions accepted")
  }
  assert_true(env.pending_inspection is None)
}
