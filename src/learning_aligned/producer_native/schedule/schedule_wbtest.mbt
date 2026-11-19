///|
/// Pending source cases: no schedule or backend execution is authorized.
fn facts() -> ManagerFacts {
  {
    num_envs: 2,
    num_substeps: 4,
    solver_dt: 0.005,
    physics_dt: 0.02,
    decimation: 1,
    single_state: true,
    use_mujoco_contacts: true,
    staged_body_forces: true,
    pre_actuator_callbacks: 1,
    has_adapter: false,
    post_actuator_callbacks: 1,
    state_force_callbacks: 1,
    post_step_callbacks: 1,
    imu_sensors: 0,
    report_contacts: false,
    contact_sensors: 0,
    particle_forces: false,
  }
}

///|
test "fixed schedule keeps all four solver substeps and dependency edges" {
  let schedule = compile(facts())
  let nodes = schedule.operations(@contracts.Step)
  let solves = nodes.filter(fn(node) { node.operation is Solver(Step(..)) })
  assert_eq(solves.length(), 4)
  for node in solves {
    let before = nodes[node.id - 1].operation
    let after = nodes[node.id + 1].operation
    assert_true(before is StateForceCallback(..))
    assert_true(after is ClearStateForces(..))
  }
  for node in nodes {
    assert_eq(node.depends_on, if node.id == 0 { [] } else { [node.id - 1] })
  }
  assert_false(nodes.any(fn(node) { node.operation is AdapterStep(..) }))
  assert_true(nodes[nodes.length() - 1].operation is Publish(dt=0.02))
  let copied = schedule.operations(@contracts.Step)
  copied[1].depends_on.clear()
  assert_eq(schedule.operations(@contracts.Step)[1].depends_on, [0])
}

///|
test "reset context and refresh retain solver invalidation and publication" {
  let schedule = compile(facts())
  let reset = schedule.operations(@contracts.Reset)
  assert_eq(reset.length(), 8)
  assert_true(reset[5].operation is Solver(ResetWarmStart(flags=0)))
  assert_true(reset[6].operation is ForwardBoundary)
  assert_true(reset[7].operation is Publish(dt=0.0))
  let context = schedule.operations(@contracts.Context)
  assert_true(context[0].operation is Solver(NotifyModelChanged))
  assert_true(context[1].operation is ForwardBoundary)
  assert_true(
    schedule.operations(@contracts.Refresh)[0].operation is ForwardBoundary,
  )
}

///|
test "unsupported fixed-profile facts fail before backend lowering" {
  for
    invalid in [
      { ..facts(), num_substeps: 3, },
      { ..facts(), solver_dt: 0.02, },
      { ..facts(), physics_dt: 0.005, },
      { ..facts(), decimation: 2, },
      { ..facts(), single_state: false, },
      { ..facts(), use_mujoco_contacts: false, },
      { ..facts(), pre_actuator_callbacks: -1, },
      { ..facts(), contact_sensors: 1, },
    ] {
    try compile(invalid) catch {
      Invalid(_) => ()
      _ => fail("unexpected error kind")
    } noraise {
      _ => fail("unsupported manager profile accepted")
    }
  }
}

///|
test "native lowering refuses missing implementations and mismatched typed addresses" {
  let allocation : @contracts.Allocation = {
    owner_id: "observed-base",
    address: 4096UL,
    bytes: 256L,
    scalar_type: @contracts.F32,
    capture_origin: None,
  }
  let captures : Array[@contracts.GraphCapture] = [
    @contracts.Step,
    @contracts.Reset,
    @contracts.Context,
    @contracts.Refresh,
  ].map(fn(role) { { role, regions: [], module_keys: [], } })
  let union = @contracts.NumericUnion::build([allocation], captures)
  let operand : NativeOperand = {
    name: "targets",
    view: {
      binding: "shared_0",
      offset_elements: 0,
      row_stride_elements: 29,
      component_stride_elements: 1,
      width: 29,
    },
    rows: 2,
    scalar_type: @contracts.F32,
    address: 4096UL,
    owner_address: 4096UL,
    owner_bytes: 256L,
  }
  validate_operands(union, [operand])
  try compile(facts()).validate_native_coverage(union, [operand], []) catch {
    MissingBackend(key) => assert_eq(key, "articulation.target")
    _ => fail("expected missing actual implementation")
  } noraise {
    _ => fail("empty native backend accepted")
  }
  for
    bad in [
      { ..operand, address: 4100UL, },
      { ..operand, owner_bytes: 252L, },
      { ..operand, scalar_type: @contracts.I32, },
    ] {
    try validate_operands(union, [bad]) catch {
      Invalid(_) => ()
      _ => fail("unexpected metadata error")
    } noraise {
      _ => fail("mismatched native buffer metadata accepted")
    }
  }
}
