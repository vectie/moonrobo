///|
/// Hand-built numeric state dictionaries test mapping independently of pickle.
fn weight_test_tensor(
  shape : Array[Int32],
  values : Array[Double],
) -> @artifacts.TorchValue {
  @artifacts.TorchTensor({ shape, dtype: "<f8", values: values.copy(), })
}

///|
fn weight_test_network(
  net : Network,
  prefix : String,
  fields : Map[String, @artifacts.TorchValue],
) -> Unit {
  let mut offset = 0
  for i in 0..<(net.dimensions.length() - 1) {
    let name = prefix + (i * (if net.layer_norm { 3 } else { 2 })).to_string()
    let nin = net.dimensions[i]
    let nout = net.dimensions[i + 1]
    fields[name + ".weight"] = weight_test_tensor(
      [nout, nin],
      net.parameters[offset:offset + nin * nout].to_owned(),
    )
    offset += nin * nout
    fields[name + ".bias"] = weight_test_tensor(
      [nout],
      net.parameters[offset:offset + nout].to_owned(),
    )
    offset += nout
    if net.layer_norm && i < net.dimensions.length() - 2 {
      let name = prefix + (i * 3 + 1).to_string()
      for suffix in [".weight", ".bias"] {
        fields[name + suffix] = weight_test_tensor(
          [nout],
          net.parameters[offset:offset + nout].to_owned(),
        )
        offset += nout
      }
    }
  }
}

///|
fn weight_test_norm(
  norm : RunningNorm,
  prefix : String,
  fields : Map[String, @artifacts.TorchValue],
) -> Unit {
  fields[prefix + ".mean"] = weight_test_tensor([norm.mean.length()], norm.mean)
  fields[prefix + ".var"] = weight_test_tensor(
    [norm.variance.length()],
    norm.variance,
  )
  fields[prefix + ".count"] = weight_test_tensor([], [norm.count])
}

///|
fn weight_test_state(learner : Learner) -> @artifacts.TorchValue {
  let wm : Map[String, @artifacts.TorchValue] = Map([])
  let pi : Map[String, @artifacts.TorchValue] = Map([])
  let critic : Map[String, @artifacts.TorchValue] = Map([])
  weight_test_network(learner.wm.net, "net.", wm)
  weight_test_network(learner.policy.encoder, "enc.", pi)
  weight_test_network(learner.policy.decoder, "dec.", pi)
  weight_test_network(learner.critic.net, "net.", critic)
  weight_test_norm(learner.wm.input_norm, "in_norm", wm)
  weight_test_norm(learner.wm.output_norm, "out_norm", wm)
  weight_test_norm(learner.policy.obs_norm, "obs_norm", pi)
  weight_test_norm(learner.policy.goal_norm, "goal_norm", pi)
  weight_test_norm(learner.critic.norm, "norm", critic)
  @artifacts.TorchDict({
    "wm": @artifacts.TorchDict(wm),
    "pi": @artifacts.TorchDict(pi),
    "critic": @artifacts.TorchDict(critic),
    "config": @artifacts.TorchDict({
      "observation_mode": @artifacts.TorchString("paper"),
    }),
  })
}

///|
test "Torch Linear LayerNorm and normalizer weights map exactly without resume" {
  let source = contract_learner()
  for
    net in [
      source.wm.net,
      source.policy.encoder,
      source.policy.decoder,
      source.critic.net,
    ] {
    for i in 0..<net.parameters.length() {
      net.parameters[i] = (i % 19).to_double() / 20.0
    }
  }
  for
    norm in [
      source.wm.input_norm,
      source.wm.output_norm,
      source.policy.obs_norm,
      source.policy.goal_norm,
      source.critic.norm,
    ] {
    norm.update([
      Array::make(norm.mean.length(), 0.2),
      Array::make(norm.mean.length(), 0.4),
    ])
  }
  let target = contract_learner()
  ignore(target.rng.normal())
  let before = target.snapshot()
  target.import_torch_weights(weight_test_state(source))
  let imported = target.snapshot()
  assert_eq(imported.parameters, source.snapshot().parameters)
  assert_eq(imported.norms.to_json(), source.snapshot().norms.to_json())
  assert_eq(imported.rng, before.rng)
  assert_eq(imported.optimizers.to_json(), before.optimizers.to_json())
  let history = Array::makei(target.config.hist, _ => {
    Array::make(target.mode.dim(), 0.1)
  })
  let goal = Array::make(73, 0.2)
  assert_eq(
    source.policy.forward(history, goal),
    target.policy.forward(history, goal),
  )
}

///|
test "Torch aligned import rejects extra keys wrong shape and nonfinite atomically" {
  let target = contract_learner()
  let state = weight_test_state(target)
  let before = target.snapshot().to_json()
  guard state.field("wm") is TorchDict(wm) else { fail("fixture dict") }
  wm["unexpected.weight"] = weight_test_tensor([1], [0.0])
  assert_true(
    (Ok(target.import_torch_weights(state)) catch { e => Err(e) }) is Err(_),
  )
  assert_eq(target.snapshot().to_json(), before)
  ignore(wm.remove("unexpected.weight"))
  let original = wm["net.0.weight"]
  wm["net.0.weight"] = weight_test_tensor([1], [0.0])
  assert_true(
    (Ok(target.import_torch_weights(state)) catch { e => Err(e) }) is Err(_),
  )
  assert_eq(target.snapshot().to_json(), before)
  wm["net.0.weight"] = original
  wm["in_norm.count"] = weight_test_tensor([], [0.0 / 0.0])
  assert_true(
    (Ok(target.import_torch_weights(state)) catch { e => Err(e) }) is Err(_),
  )
  assert_eq(target.snapshot().to_json(), before)
}

///|
test "native weights import permits optimizer options but rejects changed context" {
  let learner = contract_learner()
  let saved = learner.snapshot()
  learner.restore_weights({
    ..saved,
    config: { ..saved.config, learning_rate: 0.01, horizon: 8, },
  })
  assert_true(
    (Ok(
      learner.restore_weights({ ..saved, config: { ..saved.config, hist: 4, }, }),
    ) catch {
      e => Err(e)
    })
    is Err(_),
  )
  let bad = saved.norms.copy()
  bad[0] = { ..bad[0], variance: Array::make(133, -1.0), }
  assert_true(
    (Ok(learner.restore_weights({ ..saved, norms: bad, })) catch {
      e => Err(e)
    })
    is Err(_),
  )
}

///|
test "original training report fields omit policy before world-only warmup" {
  let learner = contract_learner()
  let metrics : IterationMetrics = {
    iteration: 1,
    learning_rate: 0.01,
    world: { loss: 0.1, last_error: 0.2, updates: 1, },
    policy: None,
    actor_readiness: None,
  }
  let row = metrics.report_json()
  guard row is Object(fields) else { fail("metric dict") }
  assert_true(fields.contains("world_model") && !fields.contains("policy"))
  let report = learner.training_report(
    {},
    { "profile": "cpu-smoke" },
    "weights-only-fresh",
    1,
    TrainingCounters::new(),
    0.5,
    [row],
    "sha",
    {},
    {},
    {},
    {},
  )
  guard report is Object(fields) else { fail("report dict") }
  for
    key in [
      "format", "profile", "identity", "config", "resume_kind", "iteration", "counters",
      "wall_seconds_this_invocation", "updates", "result_scope", "hardware_execution",
      "checkpoint_sha256", "physics_settings", "source_files", "parameters", "motion_frames",
      "dependencies",
    ] {
    assert_true(fields.contains(key))
  }
  assert_eq(fields["result_scope"], "method-integration smoke".to_json())
}
