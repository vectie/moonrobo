///|
/// Deferred translations of the original dynamics/policy/online/refit contracts.
fn contract_stats(n : Int32) -> @numeric.Normalization {
  { mean: Array::make(n, 0.0), scale: Array::make(n, 1.0), }
}

///|
fn contract_model(n~ : Int32 = 14, root~ : Bool = false) -> Dynamics {
  Dynamics::new(
    contract_stats(n),
    contract_stats(1),
    contract_stats(2),
    4,
    @numeric.Rng::new(23U),
    translation_invariant=true,
    root_integration_dt=if root { Some(0.02) } else { None },
  )
}

///|
fn contract_episode(
  id : String,
  start : Double,
  times~ : Array[Double] = [0.0, 0.02, 0.04, 0.06],
) -> Episode {
  let steps = Array::makei(times.length(), i => {
    let state = Array::make(14, 0.0)
    state[2] = 0.8
    state[3] = 1
    state[7] = start + i.to_double()
    let target = state.copy()
    target[7] += 0.1
    {
      time_s: times[i],
      state,
      observation: [],
      applied_action: [0.1 + i.to_double()],
      next_state: target,
      goal: [],
      terminated: i == times.length() - 1,
      truncated: false,
    }
  })
  { id, split: "train", context: [1.0, 1.0], steps, }
}

///|
test "validation selection is distinct from global error" {
  let metrics : DynamicsMetrics = {
    windows: 2,
    mse: 2,
    persistence_mse: 9,
    per_step_mse: [2.0],
    persistence_per_step_mse: [9.0],
    late_windows: 1,
    late_mse: Some(6),
    late_persistence_mse: Some(9),
  }
  assert_eq(validation_score(metrics, 0), 2)
  assert_eq(validation_score(metrics, 0.5), 4)
  let missing = {
    ..metrics,
    late_windows: 0,
    late_mse: None,
    late_persistence_mse: None,
  }
  assert_eq(validation_score(missing, 0), 2)
}

///|
test "panic late weighted validation rejects missing evidence" {
  ignore(
    validation_score(
      {
        windows: 1,
        mse: 2,
        persistence_mse: 9,
        per_step_mse: [2.0],
        persistence_per_step_mse: [9.0],
        late_windows: 0,
        late_mse: None,
        late_persistence_mse: None,
      },
      0.5,
    ),
  )
}

///|
test "panic late sampling rejects absent requested pool" {
  ignore(sampling_pools([0.0], 64, 0.5))
}

///|
test "unrolled XY translation and checkpoint preserve predictions and live action gradients" {
  for root in [false, true] {
    let model = contract_model(n=if root { 71 } else { 14 }, root~)
    let rng = @numeric.Rng::new(82U)
    for i in 0..<model.network.parameters.length() {
      model.network.parameters[i] = 0.03 * (2 * rng.uniform() - 1)
    }
    let state = Array::make(model.state_stats.mean.length(), 0.0)
    state[2] = 0.8
    state[3] = 1
    if root {
      state[36] = 0.1
      state[37] = -0.2
      state[38] = 0.05
    }
    let shifted = state.copy()
    shifted[0] += 2
    shifted[1] -= 3
    let actions = Array::makei(8, _ => [0.0])
    let rollout = fn(initial : Array[Double]) -> Array[Array[Double]] {
      let tape = @numeric.Tape::new()
      model
      .imagine(
        tape,
        model.network.bind(tape),
        tape.vector(initial),
        actions.map(a => tape.vector(a)),
        tape.vector([1.0, 1.0]),
      )
      .map(row => row.map(v => v.value))
    }
    let base = rollout(state)
    let translated = rollout(shifted)
    for t in 0..<8 {
      for j in 0..<state.length() {
        let offset = if j == 0 { 2.0 } else if j == 1 { -3.0 } else { 0.0 }
        assert_true(
          (translated[t][j] - offset - base[t][j]).abs() < 0.000000000001,
        )
      }
    }
    let tape = @numeric.Tape::new()
    let action_values = actions.map(a => tape.vector(a))
    let predicted = model.imagine(
      tape,
      model.network.bind(tape),
      tape.vector(state),
      action_values,
      tape.vector([1.0, 1.0]),
    )
    let last = predicted[7]
    let endpoint = if root {
      tape.add(tape.add(last[0], last[1]), last[2])
    } else {
      last[2]
    }
    tape.backward(endpoint)
    let mut norm = 0.0
    for row in action_values {
      for v in row {
        let g = tape.gradient(v)
        assert_true(@numeric.finite(g))
        norm += g * g
      }
    }
    assert_true(norm > 0)
    let restored = dynamics_from_checkpoint(model.checkpoint({}))
    let rt = @numeric.Tape::new()
    let reloaded = restored
      .imagine(
        rt,
        restored.network.bind(rt),
        rt.vector(state),
        actions.map(a => rt.vector(a)),
        rt.vector([1.0, 1.0]),
      )
      .map(row => row.map(v => v.value))
    assert_eq(reloaded, base)
  }
}

///|
test "critic XY invariance survives saved parameters and legacy input encoding" {
  let critic = Critic::new(
    contract_stats(14),
    1,
    2,
    0.99,
    @numeric.Rng::new(9U),
    translation_invariant=true,
  )
  let state = Array::makei(14, i => 0.01 * i.to_double())
  let shifted = state.copy()
  shifted[0] += 1
  shifted[1] -= 2
  assert_eq(
    critic.predict(state, [0.0], [1.0, 1.0]),
    critic.predict(shifted, [0.0], [1.0, 1.0]),
  )
  let tape = @numeric.Tape::new()
  let variables = tape.vector(state)
  tape.backward(
    critic.forward(
      tape,
      critic.network.bind(tape),
      variables,
      tape.vector([0.0]),
      tape.vector([1.0, 1.0]),
    ),
  )
  assert_eq(tape.gradient(variables[0]), 0)
  assert_eq(tape.gradient(variables[1]), 0)
  let actor = Actor::new(
    contract_stats(9),
    contract_stats(1),
    [-1.0],
    [1.0],
    0.1,
    { q_indices: [7], v_state_indices: [8], nq: 8, },
    4,
    @numeric.Rng::new(4U),
  )
  let cp = actor.checkpoint({})
  critic.put_checkpoint(cp)
  let restored = critic_from_actor_checkpoint(
    cp,
    1,
    2,
    translation_invariant=false,
  )
  assert_eq(
    restored.predict(shifted, [0.0], [1.0, 1.0]),
    critic.predict(state, [0.0], [1.0, 1.0]),
  )
}

///|
test "bootstrap ablation preserves rewards states and live boundary gradient" {
  let model = contract_model()
  let rng = @numeric.Rng::new(19U)
  for i in 0..<model.network.parameters.length() {
    model.network.parameters[i] = 0.02 * (2 * rng.uniform() - 1)
  }
  let actor = Actor::new(
    contract_stats(9),
    contract_stats(1),
    [-1.0],
    [1.0],
    0.3,
    { q_indices: [7], v_state_indices: [8], nq: 8, },
    4,
    rng,
  )
  let critic = Critic::new(contract_stats(14), 1, 2, 0.9, rng)
  let initial = Array::make(14, 0.0)
  initial[2] = 0.8
  initial[3] = 1
  let tape = @numeric.Tape::new()
  let ap = actor.network.bind(tape)
  let mp = model.network.bind(tape)
  let cp = critic.network.bind(tape)
  let state = tape.vector(initial)
  let previous = tape.vector([0.0])
  let goal = tape.vector([0.0])
  let context = tape.vector([1.0, 1.0])
  let on = imagined_rollout(
    model,
    actor,
    critic,
    tape,
    mp,
    ap,
    cp,
    state,
    previous,
    goal,
    context,
    { horizon: 3, gamma: 0.9, target_height: 0.8, bootstrap: true, },
  )
  let off = imagined_rollout(
    model,
    actor,
    critic,
    tape,
    mp,
    ap,
    cp,
    state,
    previous,
    goal,
    context,
    { horizon: 3, gamma: 0.9, target_height: 0.8, bootstrap: false, },
  )
  assert_eq(
    on.states.map(s => s.map(v => v.value)),
    off.states.map(s => s.map(v => v.value)),
  )
  assert_eq(on.rewards.map(v => v.value), off.rewards.map(v => v.value))
  let mut survival = tape.scalar(1)
  for c in on.continuations {
    survival = tape.mul(survival, c)
  }
  let boundary = tape.scale(
    tape.mul(survival, critic.forward(tape, cp, on.states[3], goal, context)),
    0.729,
  )
  assert_true(
    (on.objective.value - off.objective.value - boundary.value).abs() <
    0.000000000001,
  )
  tape.backward(on.objective)
  let g_on = ap.map(v => tape.gradient(v))
  tape.backward(off.objective)
  let g_off = ap.map(v => tape.gradient(v))
  tape.backward(boundary)
  let g_boundary = ap.map(v => tape.gradient(v))
  let mut live = 0.0
  for i in 0..<ap.length() {
    assert_true((g_on[i] - g_off[i] - g_boundary[i]).abs() < 0.0000000001)
    live += g_boundary[i] * g_boundary[i]
  }
  assert_true(live > 0)
}

///|
test "online update preserves normalization actor RNG and capped replay but changes weights" {
  let model = contract_model()
  let windows = episode_windows([contract_episode("base", 0)], 2, 0.02)
  let before = model.network.parameters.copy()
  let buffers = normalization_buffers(model).map(row => row.copy())
  let actor_rng = @numeric.Rng::new(61U)
  let rng_state = actor_rng.state()
  let updater = OnlineDynamics::new(model, windows, 4, 4, 3, 0.003, 1900U)
  let first = updater.update([contract_episode("new", 0)], 0.02)
  ignore(updater.update([contract_episode("later", 10)], 0.02))
  assert_eq(actor_rng.state(), rng_state)
  assert_eq(first.optimizer_steps, 3)
  assert_eq(updater.optimizer_steps, 6)
  assert_eq(updater.recent.length(), 4)
  assert_true(model.network.parameters != before)
  assert_eq(normalization_buffers(model), buffers)
  let probe = model.gradient_probe(windows[0])
  assert_true(probe.passed)
  assert_true(probe.action_gradient_norm > 0)
}

///|
test "panic heldout online episodes cannot enter replay" {
  let episode = contract_episode("heldout", 0)
  ignore(episode_windows([{ ..episode, split: "validation", }], 2, 0.02))
}

///|
test "actual action stride retains final endpoint and ignores teacher labels" {
  let episode = contract_episode("stream", 0, times=[
    0.0, 0.02, 0.04, 0.06, 0.08,
  ])
  let windows = episode_windows([episode], 2, 0.02, stride=2, reject_reset=true)
  assert_eq(windows.map(w => w.state[0][7]), [0.0, 2.0, 3.0])
  assert_eq(windows.map(w => w.action[0][0]), [0.1, 2.1, 3.1])
  let gaps = episode_windows(
    [contract_episode("gaps", 0, times=[0.0, 0.02, 0.1, 0.12, 0.3])],
    2,
    0.02,
    stride=2,
    reject_reset=true,
  )
  assert_eq(gaps.map(w => w.state[0][7]), [0.0, 2.0])
}

///|
async test "refit selected latest checkpoints preserve incoming units and input hash" {
  let folder = @fs.tmpdir(prefix="moonrobo-refit-contract-")
  defer (@fs.rmdir(folder, recursive=true) catch { _ => () })
  let model = contract_model()
  let data = episode_windows(
    [
      contract_episode("base", 0),
      contract_episode("late", 0, times=[2.0, 2.02, 2.04, 2.06]),
    ],
    2,
    0.02,
  )
  let frozen = normalization_buffers(model).map(row => row.copy())
  let training_sha = @artifacts.save_json(folder + "/training-input.json", {
    "base": "base",
    "added": "added",
  })
  let result = refit_dynamics(
    model,
    data,
    data,
    data,
    data,
    {
      updates: 2,
      batch_size: 4,
      evaluate_every: 1,
      learning_rate: 0.001,
      late_window_fraction: 0,
      late_validation_weight: 0.5,
    },
    @numeric.Rng::new(3U),
    true,
  )
  let selected = model.checkpoint({
    "selected_update": result.selected_update.to_json(),
    "training_batch_sha256": training_sha.to_json(),
  })
  let sha = @artifacts.save_checkpoint(folder + "/selected.moon.json", selected)
  restore_parameters(model.network, result.latest_parameters)
  ignore(
    @artifacts.save_checkpoint(
      folder + "/latest.moon.json",
      model.checkpoint({
        "selected_update": 2,
        "training_batch_sha256": training_sha.to_json(),
      }),
    ),
  )
  let restored = @artifacts.load_checkpoint(
    folder + "/selected.moon.json",
    "residual-dynamics",
    expected_sha256=sha,
  )
  let latest = @artifacts.load_checkpoint(
    folder + "/latest.moon.json",
    "residual-dynamics",
  )
  assert_eq(
    json_field(restored.metadata, "training_batch_sha256"),
    training_sha.to_json(),
  )
  assert_eq(json_field(latest.metadata, "selected_update"), (2).to_json())
  assert_eq(normalization_buffers(dynamics_from_checkpoint(restored)), frozen)
  assert_eq(normalization_buffers(dynamics_from_checkpoint(latest)), frozen)
  assert_eq(
    refit_metrics_json(dynamics_from_checkpoint(restored).evaluate(data)),
    refit_metrics_json(result.test_metrics),
  )
}

///|
/// Manifest fixture includes deliberately wrong teacher targets: only physical applied controls may enter fit.
async fn contract_manifest(folder : String, split : String) -> (String, String) {
  let layout : Json = {
    "model_ref": "toy",
    "dt_s": 0.02,
    "frame_convention": "toy",
    "state_axes": Array::make(14, Json::null()).to_json(),
    "action_axes": [null],
    "context_axes": [null, null],
  }
  let episode = contract_episode("one", 0, times=[0.0, 0.02, 0.04, 0.06, 0.08])
  let steps = episode.steps.map(s => {
    "time_s": s.time_s.to_json(),
    "state": s.state.to_json(),
    "next_state": s.next_state.to_json(),
    "applied_action": s.applied_action.to_json(),
    "terminated": s.terminated.to_json(),
    "truncated": s.truncated.to_json(),
  })
  let row : Json = {
    "id": "one",
    "split": split.to_json(),
    "context": [1, 1],
    "steps": steps.to_json(),
  }
  let dataset : Json = match layout {
    Object(fields) => {
      let fields = fields.copy()
      fields["episodes"] = [row].to_json()
      Json::object(fields)
    }
    _ => abort("layout")
  }
  let source = folder + "/student.jsonl.gz"
  let stored = @artifacts.compress_gzip(
    @utf8.encode(
      ({ "dataset": dataset, "teacher_action_targets": [[[999]]] } : Json).stringify() +
      "\n",
    ),
  )
  @fs.write_file(source, stored, create_mode=CreateOrTruncate)
  let manifest : Json = {
    "format": "moonrobo.g1-actual-action-streams.v1",
    "split": "train",
    "layout": layout,
    "window_length": 2,
    "stride": 2,
    "episodes": 1,
    "sources": [
      {
        "kind": "student-jsonl-gzip",
        "path": source.to_json(),
        "sha256": @artifacts.sha256(stored).to_json(),
        "chunks": [{ "episodes": 1, "transitions": 5 }],
      },
    ],
  }
  let path = folder + "/manifest.json"
  ignore(@artifacts.save_json(path, manifest))
  (path, source)
}

///|
async test "native actual stream excludes teacher labels and rejects heldout or modified bytes" {
  let folder = @fs.tmpdir(prefix="moonrobo-stream-contract-")
  defer (@fs.rmdir(folder, recursive=true) catch { _ => () })
  let (path, source) = contract_manifest(folder, "train")
  let batch = load_actual_actions(path)
  assert_eq(batch.windows.map(w => w.state[0][7]), [0.0, 2.0, 3.0])
  assert_eq(batch.windows.map(w => w.action[0][0]), [0.1, 2.1, 3.1])
  assert_eq(batch.episodes, 1)
  assert_eq(batch.transitions, 5)
  let (heldout, _) = contract_manifest(folder, "test")
  let rejected = try load_actual_actions(heldout) catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(rejected)
  @fs.write_file(source, b"changed", create_mode=CreateOrTruncate)
  let modified = try load_actual_actions(path) catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(modified)
}
