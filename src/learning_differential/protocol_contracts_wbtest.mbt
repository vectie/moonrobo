///|
using @protocol {type ProtocolConfig, type TrackingProtocol, type BatchAdapter}

// Source port of test_aligned_isaac.py's CPU protocol fixtures. These tests call
// the real TrackingProtocol implementation with an explicitly synthetic adapter.
// They do not assert that CUDA, Newton, Kit or the APIC graphs have executed.

///|
struct ContractDevice {
  states : Array[@aligned.State]
  targets : Array[Array[Double]]
  resets : Array[Array[Int32]]
  contexts : Array[Array[Int32]]
  steps : Array[(Int32, Double)]
  reads : Array[Int32]
  mu : Array[Double]
  com : Array[Array[Double]]
}

///|
fn contract_state() -> @aligned.State {
  {
    p: [0.0, 0.0, 0.76],
    rotation: @aligned.identity(),
    v: [0.0, 0.0, 0.0],
    w: [0.0, 0.0, 0.0],
    q: @aligned.default_joint_positions(),
    qd: Array::make(29, 0.0),
  }
}

///|
fn contract_kin() -> @aligned.Kinematics {
  {
    bodies: [
      {
        name: "pelvis",
        parent: -1,
        joint: -1,
        axis: [0.0, 0.0, 1.0],
        offset_p: [0.0, 0.0, 0.0],
        offset_rotation: @aligned.identity(),
        pivot: [0.0, 0.0, 0.0],
        qref: 0.0,
      },
    ],
    tracked: Array::make(14, 0),
    q_lo: Array::make(29, -3.0),
    q_hi: Array::make(29, 3.0),
  }
}

///|
fn contract_motion(kin : @aligned.Kinematics) -> @aligned.MotionLibrary {
  let states = Array::makei(5, _ => contract_state())
  {
    names: ["contract"],
    source_sha256: ["contract-fixture-only"],
    source_fps: 50.0,
    states: @aligned.FrameStore::eager(states),
    bodies: @aligned.FrameStore::eager(states.map(s => kin.forward(s))),
    clip_start: [0],
    clip_end: [4],
    clip_id: @aligned.FrameStore::eager(Array::make(5, 0)),
    bins: [{ start: 0, clip_end: 4, }],
    frame_bin: @aligned.FrameStore::eager(Array::make(5, 0)),
    orthonormal_heading: false,
  }
}

///|
fn contract_config(
  context_resampling~ : String = "environment",
  physics_dt~ : Double = 0.005,
  max_episode_steps~ : Int32 = 500,
) -> ProtocolConfig {
  {
    asset_path: "contract-fixture.usda",
    asset_sha256: "fixture-only",
    gamma: 0.99,
    self_collisions: true,
    reset_noise: false,
    max_episode_steps,
    context_resampling,
    physics_dt,
  }
}

///|
fn ContractDevice::new(n~ : Int32 = 2) -> ContractDevice {
  {
    states: Array::makei(n, _ => contract_state()),
    targets: Array::makei(n, _ => Array::make(29, 0.0)),
    resets: [],
    contexts: [],
    steps: [],
    reads: [],
    mu: Array::make(n, 0.0),
    com: Array::makei(n, _ => [0.1, 0.2, 0.3]),
  }
}

///|
fn clone_contract_state(s : @aligned.State) -> @aligned.State {
  @aligned.unflatten_state(@aligned.flatten_state(s))
}

///|
fn ContractDevice::adapter(
  self : ContractDevice,
  names? : Array[String],
) -> BatchAdapter {
  {
    backend: "explicit-cpu-contract-fixture",
    num_envs: self.states.length(),
    joint_names: names.unwrap_or(@aligned.joint_names()),
    read_states: () => {
      self.reads.push(1)
      self.states.map(clone_contract_state)
    },
    write_resets: (ids, states) => {
      self.resets.push(ids.copy())
      for k, id in ids {
        self.states[id] = clone_contract_state(states[k])
      }
    },
    apply_context: (ids, rows, ground) => {
      guard ground == 0.3 || ground == 1.0 else {
        fail("contract ground friction")
      }
      self.contexts.push(ids.copy())
      for k, id in ids {
        self.mu[id] = rows[k][0]
        self.com[id] = Array::makei(3, j => [0.1, 0.2, 0.3][j] + rows[k][30 + j])
      }
    },
    step_substeps: (targets, count, dt) => {
      self.steps.push((count, dt))
      for i, row in targets {
        self.targets[i] = row.copy()
        self.states[i].p[0] += 0.01
      }
    },
    synchronize: () => (),
  }
}

///|
fn contract_env(
  device : ContractDevice,
  config? : ProtocolConfig,
  reuse_pre_step_state~ : Bool = false,
) -> TrackingProtocol raise {
  let kin = contract_kin()
  TrackingProtocol::new(
    device.adapter(),
    kin,
    contract_motion(kin),
    config.unwrap_or(contract_config()),
    seed=31U,
    reuse_pre_step_state~,
  )
}

///|
fn protocol_solver() -> Unit raise {
  let device = ContractDevice::new()
  let env = contract_env(device)
  env.reset(frames=[0, 0])
  ignore(env.step(Array::makei(2, _ => Array::make(29, 0.0))))
  assert_eq(device.steps, [(4, 0.005)])
  assert_eq(4.0 * 0.005, 0.02)
  let rejected = try {
    ignore(contract_env(device, config=contract_config(physics_dt=0.002)))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}

///|
fn protocol_joint_order() -> Unit raise {
  let device = ContractDevice::new()
  let names = @aligned.joint_names()
  let first = names[0]
  names[0] = names[1]
  names[1] = first
  let kin = contract_kin()
  let rejected = try {
    ignore(
      TrackingProtocol::new(
        device.adapter(names~),
        kin,
        contract_motion(kin),
        contract_config(),
      ),
    )
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  assert_eq(device.reads.length(), 0)
  assert_eq(device.resets.length(), 0)
  assert_eq(device.contexts.length(), 0)
}

///|
fn protocol_transition() -> Unit raise {
  let device = ContractDevice::new()
  let env = contract_env(device)
  env.reset(frames=[0, 3])
  let previous_xi = env.xi.map(row => row.copy())
  let result = env.step(Array::makei(2, _ => Array::make(29, 1.0)))
  assert_eq(result.transitions.map(t => t.frame), [0, 3])
  assert_eq(result.done, [false, true])
  assert_eq(result.timeout, [false, true])
  assert_eq(result.transitions.map(t => t.terminated), [false, false])
  assert_eq(result.transitions.map(t => t.truncated), [false, true])
  assert_eq(result.transitions.map(t => t.xi), previous_xi)
  assert_eq(result.transitions[1].s[0], 0.0)
  assert_eq(result.transitions[1].s1[0], 0.01)
  assert_eq(env.episode_steps, [1, 0])
  assert_eq(result.reset_ids, [1])
  assert_eq(
    device.targets[0],
    @aligned.action_to_setpoint(
      Array::make(29, 1.0),
      calibration=previous_xi[0][1:30].to_owned(),
    ),
  )
  assert_eq(env.sampler.snapshot().2, [1])
}

///|
fn protocol_evaluation() -> Unit raise {
  let device = ContractDevice::new()
  let env = contract_env(device, config=contract_config(max_episode_steps=1))
  env.for_evaluation()
  assert_true(env.eval_mode)
  assert_true(env.xi.all(row => row[0] == 1.0 && row[1:33].all(x => x == 0.0)))
  assert_eq(device.mu, [1.0, 1.0])
  assert_eq(device.com, [[0.1, 0.2, 0.3], [0.1, 0.2, 0.3]])
  env.evaluation_reset(0)
  let first = env.evaluation_step(Array::make(29, 0.0))
  assert_true(!first.terminated && !first.truncated)
  env.evaluation_reset(3)
  let last = env.evaluation_step(Array::make(29, 0.0))
  assert_true(last.truncated)
  assert_eq(env.frames, [4, 4])
  let exhausted = env.evaluation_step(Array::make(29, 0.0))
  assert_eq(exhausted.r, 0.0)
  assert_eq(env.frames, [4, 4])
}

///|
fn protocol_resume() -> Unit raise {
  let device = ContractDevice::new()
  let env = contract_env(device)
  env.reset(frames=[3, 3])
  let saved = env.snapshot()
  assert_true(!saved.exact_resume && saved.replay_refill_required)
  let report = env.restore(saved)
  assert_eq(report, {
    "exact_resume": false,
    "replay_refill_required": true,
    "physical_episodes_reset": 2,
  })
  assert_eq(env.episode_steps, [0, 0])
  assert_eq(env.previous, Array::makei(2, _ => Array::make(29, 0.0)))
  let mismatch = {
    ..saved,
    config: { ..saved.config, self_collisions: false, },
  }
  let rejected = try {
    ignore(env.restore(mismatch))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}

///|
fn protocol_context() -> Unit raise {
  let device = ContractDevice::new()
  let env = contract_env(device)
  let saved = env.snapshot()
  ignore(env.restore(saved))
  assert_eq(env.xi.map(row => row[0]), saved.xi.map(row => row[0]))
  assert_eq(
    env.xi.map(row => row[30:33].to_owned()),
    saved.xi.map(row => row[30:33].to_owned()),
  )
  assert_eq(device.mu, saved.xi.map(row => row[0]))
  for i in 0..<2 {
    assert_eq(
      device.com[i],
      Array::makei(3, j => [0.1, 0.2, 0.3][j] + saved.xi[i][30 + j]),
    )
  }
  assert_true(env.xi.all(row => row[1:30].all(x => x.abs() <= 0.01)))
  assert_true(
    env.xi.map(row => row[1:30].to_owned()) !=
    saved.xi.map(row => row[1:30].to_owned()),
  )
}

///|
fn protocol_raw_action() -> Unit raise {
  let device = ContractDevice::new()
  let env = contract_env(device)
  env.for_evaluation()
  env.evaluation_reset(0)
  let transition = env.evaluation_step(Array::make(29, 25.0))
  assert_eq(transition.a, Array::make(29, 25.0))
  assert_eq(
    device.targets,
    Array::makei(2, _ => @aligned.action_to_setpoint(Array::make(29, 25.0))),
  )
}

///|
fn protocol_episode_context() -> Unit raise {
  let device = ContractDevice::new()
  let env = contract_env(
    device,
    config=contract_config(context_resampling="episode"),
  )
  let before = env.xi.map(row => row.copy())
  let mu = device.mu.copy()
  let com = device.com.map(row => row.copy())
  env.reset(ids=[1], frames=[0])
  assert_eq(env.xi[0], before[0])
  assert_true(env.xi[1] != before[1])
  assert_true(
    env.xi[1][0] >= 0.3 &&
    env.xi[1][0] <= 1.2 &&
    env.xi[1][30].abs() <= 0.025 &&
    env.xi[1][31:33].all(x => x.abs() <= 0.05),
  )
  assert_eq(device.mu[0], mu[0])
  assert_eq(device.com[0], com[0])
  assert_eq(device.mu[1], env.xi[1][0])
  assert_eq(device.contexts[device.contexts.length() - 1], [1])
  let saved = env.snapshot()
  let rejected = try {
    ignore(
      env.restore({
        ..saved,
        config: { ..saved.config, context_resampling: "environment", },
      }),
    )
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}
