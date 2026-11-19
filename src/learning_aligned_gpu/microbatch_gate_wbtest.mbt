///|
fn gate_transfer(
  backend : @tensor.Backend,
  tensor : @tensor.Tensor,
  device : Int32,
) -> @tensor.Tensor raise {
  backend.from_values(
    tensor.shape(),
    tensor.values(),
    cuda_device=device,
    requires_grad=false,
    dtype=tensor.dtype(),
  )
}

///|
fn gate_batches(
  backend : @tensor.Backend,
  device : Int32,
  epochs : Int32,
) -> (WorldBatch, PolicyBatch) raise {
  let w = world_batch_slice(micro_world_batch(backend), 0, 4)
  let p = policy_batch_slice(micro_policy_batch(backend), 0, 4)
  (
    {
      s: gate_transfer(backend, w.s, device),
      s1: gate_transfer(backend, w.s1, device),
      xi: gate_transfer(backend, w.xi, device),
      actions: gate_transfer(backend, w.actions, device),
      mask: gate_transfer(backend, w.mask, device),
    },
    {
      state: gate_transfer(backend, p.state, device),
      previous: gate_transfer(backend, p.previous, device),
      xi: gate_transfer(backend, p.xi, device),
      history: gate_transfer(backend, p.history, device),
      references: p.references.map(s => {
        @geometry.State::from_flat71(
          backend,
          gate_transfer(backend, s.flatten71(backend), device),
        )
      }),
      goals: p.goals.map(g => gate_transfer(backend, g, device)),
      reference_fk: None,
      step_noise: p.step_noise.map(g => gate_transfer(backend, g, device)),
      critic_orders: Array::makei(epochs, epoch => {
        backend.from_values(
          [128],
          Array::makei(128, i => ((i * 37 + epoch * 17) % 128).to_double()),
          cuda_device=device,
          requires_grad=false,
          dtype=Int64,
        )
      }),
    },
  )
}

///|
fn gate_input_identity(
  backend : @tensor.Backend,
  w : WorldBatch,
  p : PolicyBatch,
) -> Json raise {
  let values = [
    w.s,
    w.s1,
    w.actions,
    w.xi,
    w.mask,
    p.state,
    p.previous,
    p.xi,
    p.history,
  ]
  for reference in p.references {
    values.push(reference.flatten71(backend))
  }
  values.append(p.goals)
  values.append(p.step_noise)
  {
    "float_tensors": Json(values.map(t => tensor_state_digest(t))),
    "critic_orders": Json(p.critic_orders.map(t => t.values())),
  }
}

///|
// Observe the actual imagined trajectories through the private production
// chunk routine without taking an optimizer step or mutating learner norms.
// This is a separately identified extra probe, not another training update.
async fn gate_gae_probe(
  root : String,
  phase : String,
  learner : Learner,
  batch : PolicyBatch,
) -> (Double, RunningNorm) {
  learner.opt_world.zero_grad()
  learner.opt_critic.zero_grad()
  learner.opt_policy.zero_grad()
  let frozen_world = learner.world.net.frozen()
  let frozen_critic = learner.critic.net.frozen()
  let width = if learner.execution.actor_microbatch == 0 { 4 } else { 2 }
  let inputs = []
  let rewards = []
  let failures = []
  let mut loss = 0.0
  for start = 0; start < 4; start = start + width {
    let chunk = learner.backward_actor_chunk(
      policy_batch_slice(batch, start, width),
      4,
      frozen_world,
      frozen_critic,
      true,
    )
    inputs.push(chunk.critic_input.unwrap())
    rewards.push(chunk.rewards)
    failures.push(chunk.failures)
    loss += chunk.loss.values()[0]
  }
  let input = learner.backend.concat(inputs, axis=1).reshape([132, 914])
  let reward = learner.backend.concat(rewards, axis=1)
  let failure = learner.backend.concat(failures, axis=1)
  inputs.clear()
  rewards.clear()
  failures.clear()
  let original = learner.critic.norm
  let norm : RunningNorm = {
    compiled_bf16_input: None,
    smc_statistics: false,
    mean: original.mean,
    variance: original.variance,
    count: original.count,
    dim: original.dim,
    eps: original.eps,
    max_count: original.max_count,
  }
  norm.update(input)
  let critic : Critic = { net: frozen_critic, norm, }
  let values = critic.forward(input).reshape([33, 4]).stop_gradient()
  let gae = lambda_returns(
    learner.backend,
    reward,
    values,
    failure,
    gamma=learner.config.gamma,
    lam=learner.config.lam,
  )
  let directory = root + "/" + phase
  @fs.mkdir(directory)
  let records = [
    gate_values_record(directory, "actor-objective", [loss]),
    gate_tensor_record(directory, "critic-input", input),
    gate_tensor_record(directory, "rewards", reward),
    gate_tensor_record(directory, "failures", failure),
    gate_tensor_record(directory, "values", values),
    gate_tensor_record(directory, "gae", gae),
    gate_tensor_record(directory, "updated-critic-mean", norm.mean),
    gate_tensor_record(directory, "updated-critic-variance", norm.variance),
  ]
  for i, p in learner.policy.parameters() {
    records.push(
      gate_tensor_record(directory, "policy-probe-gradient-\{i}", p.gradient()),
    )
  }
  gate_json(directory + "/snapshot.json", {
    "format": "moonrobo.microbatch-numerical-snapshot.v1",
    "phase": Json(phase),
    "optimizer_metadata": [],
    "normalizer_counts": [Json(norm.count)],
    "records": Json(records),
    "extra_probe_without_optimizer_step": true,
    "memory": gate_memory(learner.backend, learner.cuda_device),
  })
  (loss, norm)
}

///|
async test "opt-in isolated native microbatch numerical gate" {
  guard @env.get_env_var("MOONROBO_MICROBATCH_GATE_MODE") is Some(mode) else {
    println(
      "SKIP opt-in GPU gate; set explicit MODE/PROFILE/OUTPUT. No GPU execution.",
    )
    return
  }
  guard mode == "full" || mode == "split" else {
    fail("gate MODE must be full or split")
  }
  let profile = @env.get_env_var("MOONROBO_MICROBATCH_GATE_PROFILE").unwrap_or(
    "",
  )
  guard profile == "paper-cuda" || profile == "cpu-smoke" else {
    fail("gate PROFILE must explicitly be paper-cuda or cpu-smoke")
  }
  let device = if profile == "paper-cuda" { 0 } else { -1 }
  let root = @env.get_env_var("MOONROBO_MICROBATCH_GATE_OUTPUT").unwrap_or("")
  guard root.has_prefix("/") && @fs.kind(root) is Directory else {
    fail("gate OUTPUT must be an existing absolute directory")
  }
  let output = root + "/" + mode
  guard !@fs.exists(output) else {
    fail("refusing to overwrite an existing gate mode; use a fresh output root")
  }
  @fs.mkdir(output)
  let library = @env.get_env_var("MOONROBO_TENSOR_LIBRARY").unwrap_or("")
  guard library.has_prefix("/") else {
    fail("absolute MOONROBO_TENSOR_LIBRARY required")
  }
  let plugin_sha = gate_file_sha(library)
  let backend = @tensor.Backend::open(library)
  let before = gate_memory(backend, device)
  if device >= 0 {
    guard @env.get_env_var("NVIDIA_TF32_OVERRIDE") == Some("0") &&
      @env.get_env_var("CUBLAS_WORKSPACE_CONFIG") == Some(":4096:8") else {
      fail(
        "CUDA gate requires NVIDIA_TF32_OVERRIDE=0 and CUBLAS_WORKSPACE_CONFIG=:4096:8 before process startup",
      )
    }
    gate_memory_budget(before)
  }
  gate_json(output + "/preflight.json", before)
  let base = if device >= 0 {
    @aligned.LearnerConfig::default()
  } else {
    micro_config()
  }
  let config = { ..base, wm_batch: 4, policy_batch: 4, wm_batches: 1, }
  let context = @geometry.Context::new(
    backend,
    micro_context(backend).kin,
    device,
  )
  let chunk = if mode == "full" { 0 } else { 2 }
  let learner = Learner::new(
    backend,
    context,
    config~,
    cuda_device=device,
    seed=1U,
    world_microbatch=chunk,
    actor_microbatch=chunk,
  )
  let (world, policy) = gate_batches(backend, device, config.critic_epochs)
  let identity = gate_input_identity(backend, world, policy)
  let initial = learner.shared_state_digest()
  learner.observe(
    world.s.reshape([32, 71]),
    world.actions.reshape([32, 29]),
    world.xi.reshape([32, 33]),
    world.s1.reshape([32, 71]),
  )
  learner.policy.update_normalizers(
    policy.history.reshape([40, 93]),
    policy.goals[0],
  )
  let phases = []
  for iteration in 1..<=2 {
    let metric = learner.fit_world_batch(world)
    let phase = "world-\{iteration}"
    gate_snapshot(output, phase, learner, [
      metric.wm_loss,
      metric.wm_error_last,
      metric.wm_updates.to_double(),
    ])
    phases.push(phase)
  }
  for iteration in 1..<=2 {
    let probe = "actor-\{iteration}-probe"
    let (probe_loss, probe_norm) = gate_gae_probe(
      output, probe, learner, policy,
    )
    phases.push(probe)
    let metric = learner.update_policy(policy)
    micro_near(
      [probe_loss],
      [metric.policy_loss],
      "probe vs production actor objective",
    )
    micro_near(
      probe_norm.mean.values(),
      learner.critic.norm.mean.values(),
      "probe vs production critic norm mean",
    )
    micro_near(
      probe_norm.variance.values(),
      learner.critic.norm.variance.values(),
      "probe vs production critic norm variance",
    )
    assert_eq(probe_norm.count, learner.critic.norm.count)
    let phase = "actor-\{iteration}"
    gate_snapshot(output, phase, learner, [
      metric.policy_loss,
      metric.critic_loss,
      metric.imagined_reward,
      metric.imagined_survival,
      metric.imagined_steps.to_double(),
      metric.critic_updates.to_double(),
    ])
    phases.push(phase)
    assert_eq(learner.critic.norm.count, (132 * iteration).to_double())
  }
  let binary_sha : Json = if device >= 0 {
    Json(gate_file_sha("/proc/self/exe"))
  } else {
    Json::null()
  }
  gate_json(output + "/run.json", {
    "format": "moonrobo.microbatch-numerical-run.v1",
    "completed": true,
    "profile": Json(profile),
    "mode": Json(mode),
    "cuda_device": Json(device),
    "precision": "float32",
    "seed": 1,
    "logical_batch": 4,
    "config": Json(config),
    "execution": Json(learner.batch_execution()),
    "input_identity": identity,
    "initial_shared_state": Json(initial),
    "phases": Json(phases),
    "plugin_sha256": Json(plugin_sha),
    "binary_sha256": binary_sha,
    "absolute_tolerance": 0.000002,
    "relative_tolerance": 0.0002,
    "kinematics": "bounded single-root synthetic fixture with 14 repeated tracked bodies; no physics execution",
    "extra_probe_rollouts": 2,
    "world_optimizer_updates": 2,
    "actor_optimizer_updates": 2,
    "probe_matches_production_objective_and_critic_norm": true,
    "critic_optimizer_updates": Json(
      2 * config.critic_epochs * config.critic_minibatches,
    ),
    "final_memory": gate_memory(backend, device),
    "bitwise_equality_claimed": false,
    "numerical_comparison_completed": false,
    "peak_memory_requires_external_watch": true,
  })
  println("\{profile} \{mode} numerical snapshots complete: \{output}/run.json")
}
