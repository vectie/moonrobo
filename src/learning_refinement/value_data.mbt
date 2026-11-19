///|
struct Origin {
  case_id : String
  start_step : Int32
  integration : Array[Double]
  state : Array[Double]
  history : Array[Array[Double]]
  goals : Array[Array[Double]]
  context : Array[Double]
  remaining_steps : Int32
  reference : Array[@native_physics.Transition]
  reference_full_steps : Int32
} derive(ToJson)

///|
struct ValueData {
  episodes : Array[@native_physics.Episode]
  raw : Array[Json]
  points : Array[@temporal.ValuePoint]
  origins : Array[Origin]
}

///|
fn collect_value_data(
  runtime : @native_physics.Runtime,
  actor : @temporal.TemporalPolicy,
  collection : Json,
  config : Json,
  reset : Int32,
  capture : Bool,
) -> ValueData raise {
  let episodes = []
  let raw = []
  let points = []
  let origins = []
  let probe_cases : Array[String] = if capture {
    @json.from_json(field(config, "probe_cases"))
  } else {
    []
  }
  let probe_steps : Array[Int32] = if capture {
    @json.from_json(field(config, "probe_steps"))
  } else {
    []
  }
  let dt = number(collection, "control_dt_s")
  for case_json in array(collection, "cases") {
    guard text(case_json, "split") == "train" else {
      fail("temporal value collection must be training-only")
    }
    let snapshots : Map[Int32, Array[Double]] = Map([])
    let active_steps = if probe_cases.contains(text(case_json, "id")) {
      probe_steps
    } else {
      []
    }
    let (episode, _, raw_episode) = rollout(
      runtime, actor, case_json, reset, config, dt, snapshots, active_steps,
    )
    let reference = case_reference(runtime, case_json, raw_episode)
    let fresh = @temporal_native.episode_value_points(
      episode,
      actor,
      dt,
      number(config, "duration_s"),
      number(config, "gamma"),
      number(config, "target_height_m"),
      reference,
    )
    episodes.push(episode)
    raw.push(raw_episode)
    points.append(fresh)
    for step in active_steps {
      guard snapshots.get(step) is Some(integration) else { continue }
      let remaining_steps = (number(config, "duration_s") / dt).to_int() - step
      let count = remaining_steps + 11
      let recorded = Array::makei(
        (episode.steps.length() - step).min(integer(config, "horizon")),
        i => episode.steps[step + i],
      )
      origins.push({
        case_id: text(case_json, "id"),
        start_step: step,
        integration,
        state: episode.steps[step].state,
        history: fresh[step].history,
        goals: Array::makei(count, i => reference((step + i).to_double() * dt)),
        context: episode.context,
        remaining_steps,
        reference: recorded,
        reference_full_steps: episode.steps.length() - step,
      })
    }
  }
  guard !points.is_empty() else { fail("empty temporal value calibration") }
  { episodes, raw, points, origins, }
}

///|
fn value_error(
  value : @temporal.TemporalValue,
  points : Array[@temporal.ValuePoint],
) -> Json raise {
  guard !points.is_empty() else { fail("empty value audit") }
  let mut mae = 0.0
  let mut squared = 0.0
  let mut predictions = 0.0
  let mut targets = 0.0
  for p in points {
    let predicted = value.predict(
      p.state,
      p.history,
      Array::makei(11, i => p.goals[i]),
      p.context,
      p.remaining,
    )
    let d = predicted - p.target
    mae += d.abs()
    squared += d * d
    predictions += predicted
    targets += p.target
  }
  let count = points.length().to_double()
  {
    "points": points.length().to_json(),
    "mae": (mae / count).to_json(),
    "rmse": (squared / count).sqrt().to_json(),
    "mean_prediction": (predictions / count).to_json(),
    "mean_target": (targets / count).to_json(),
  }
}

///|
fn fit_value(
  value : @temporal.TemporalValue,
  optimizer : @numeric.Adam,
  points : Array[@temporal.ValuePoint],
  config : Json,
  rng : @numeric.Rng,
) -> Json raise {
  let before = value_error(value, points)
  for _ in 0..<integer(config, "critic_fit_steps") {
    let batch = Array::makei(integer(config, "critic_batch_size"), _ => {
      points[rng.index(points.length())]
    })
    ignore(value.fit_update(optimizer, batch))
  }
  { "before": before, "after": value_error(value, points) }
}

///|
fn data_json(
  runtime : @native_physics.Runtime,
  data : ValueData,
  collection : Json,
) -> Json raise {
  runtime.dataset(
    data.episodes,
    text(collection, "source_revision"),
    dt=number(collection, "control_dt_s"),
    episode_json=data.raw,
  )
}

///|
struct PhysicalReturn {
  local_return : Double
  full_return : Double
  states : Array[Array[Double]]
  actions : Array[Array[Double]]
  steps : Int32
}

///|
fn physical_return(
  runtime : @native_physics.Runtime,
  actor : @temporal.TemporalPolicy,
  origin : Origin,
  config : Json,
  dt : Double,
) -> PhysicalReturn raise {
  let original = runtime.integration()
  defer (try! runtime.set_integration(original))
  runtime.set_friction(origin.context[0])
  runtime.set_integration(origin.integration)
  let history = origin.history.map(row => row.copy())
  let nu = actor.base.lower.length()
  let last = history[history.length() - 1]
  let mut previous = Array::makei(nu, i => last[last.length() - nu + i])
  let mut survival = 1.0
  let mut discount = 1.0
  let mut full_return = 0.0
  let mut local_return = 0.0
  let states = []
  let actions = []
  let substeps = runtime.control_substeps(dt)
  for t in 0..<origin.remaining_steps {
    let h = Array::makei(actor.temporal.history_length, i => {
      history[history.length() - actor.temporal.history_length + i]
    })
    let action = runtime.clip_control(
      actor.predict(
        h,
        origin.goals[t],
        Array::makei(actor.temporal.future_length, i => origin.goals[t + i + 1]),
      ),
    )
    let state = runtime.step(action, substeps)
    let tape = @numeric.Tape::new()
    let (reward, continuation) = @training.step_reward(
      tape,
      tape.vector(state),
      tape.vector(action),
      tape.vector(previous),
      tape.vector(origin.goals[t]),
      actor.base.body.q_indices,
      number(config, "target_height_m"),
    )
    let value = discount * survival * reward.value
    full_return += value
    if t < integer(config, "horizon") {
      local_return += value
      states.push(state)
      actions.push(action)
    }
    survival *= continuation.value
    discount *= number(config, "gamma")
    previous = action
    if runtime.root_height() < number(config, "fall_height_m") ||
      runtime.upright() < number(config, "fall_upright_z") {
      return { local_return, full_return, states, actions, steps: t + 1, }
    }
    ignore(history.remove(0))
    history.push(runtime.observation(action))
  }
  { local_return, full_return, states, actions, steps: origin.remaining_steps, }
}

///|
fn finite_objective(
  model : @training.Dynamics,
  actor : @temporal.TemporalPolicy,
  value : @temporal.TemporalValue,
  points : Array[@temporal.ValuePoint],
  config : @training.RolloutConfig,
) -> Double {
  let tape = @numeric.Tape::new()
  let model_parameters = model.network.bind(tape)
  let actor_parameters = tape.vector(actor.parameters())
  let value_parameters = value.net.bind(tape)
  tape.mean(
    points.map(p => {
      @temporal.finite_imagination(
        model, actor, value, tape, model_parameters, actor_parameters, value_parameters,
        p, config,
      )
    }),
  ).value
}

///|
async fn direction_probe(
  runtime : @native_physics.Runtime,
  model : @training.Dynamics,
  actor : @temporal.TemporalPolicy,
  value : @temporal.TemporalValue,
  origins : Array[Origin],
  config : Json,
  rollout_config : @training.RolloutConfig,
  path : String,
) -> Json {
  guard !origins.is_empty() else {
    fail("initial direction probe captured no declared origins")
  }
  let points : Array[@temporal.ValuePoint] = origins.map(o => {
    state: o.state,
    history: o.history,
    goals: o.goals,
    context: o.context,
    remaining: o.remaining_steps.to_double() * value.dt,
    target: 0.0,
  })
  let candidate = @temporal.temporal_from_checkpoint(actor.checkpoint({}))
  let before = finite_objective(model, actor, value, points, rollout_config)
  let (_, norm) = @temporal.imagination_update(
    model,
    candidate,
    value,
    @numeric.Adam::new(
      candidate.parameters().length(),
      number(config, "actor_learning_rate"),
    ),
    points,
    rollout_config,
  )
  let after = finite_objective(model, candidate, value, points, rollout_config)
  let old = actor.parameters()
  let changed = candidate.parameters()
  let delta = Array::makei(old.length(), i => changed[i] - old[i])
  let direction = @artifacts.Checkpoint::new("temporal-actor-direction", {
    "config": config,
    "actor_state_sha256": @artifacts.sha256(
      @utf8.encode(old.to_json().stringify()),
    ).to_json(),
  })
  direction.put("direction", [delta.length()], delta)
  let sha = @artifacts.save_checkpoint(path, direction)
  let records : Array[Json] = []
  let mut maximum_restore_error = 0.0
  let mut local_change = 0.0
  let mut full_change = 0.0
  for origin in origins {
    let baseline = physical_return(runtime, actor, origin, config, value.dt)
    guard baseline.states.length() == origin.reference.length() &&
      baseline.steps == origin.reference_full_steps else {
      fail("temporal value probe restore length differs")
    }
    for i in 0..<baseline.states.length() {
      for
        (actual, expected) in [
          (baseline.states[i], origin.reference[i].next_state),
          (baseline.actions[i], origin.reference[i].applied_action),
        ] {
        for j in 0..<actual.length() {
          maximum_restore_error = maximum_restore_error.max(
            (actual[j] - expected[j]).abs(),
          )
        }
      }
    }
    guard maximum_restore_error <= 0.00000001 else {
      fail("temporal value probe restored trajectory differs")
    }
    let perturbed = physical_return(
      runtime,
      candidate,
      origin,
      config,
      value.dt,
    )
    local_change += perturbed.local_return - baseline.local_return
    full_change += perturbed.full_return - baseline.full_return
    records.push({
      "case": origin.case_id.to_json(),
      "start_step": origin.start_step.to_json(),
      "baseline": {
        "local_return": baseline.local_return.to_json(),
        "full_return": baseline.full_return.to_json(),
        "steps": baseline.steps.to_json(),
      },
      "candidate": {
        "local_return": perturbed.local_return.to_json(),
        "full_return": perturbed.full_return.to_json(),
        "steps": perturbed.steps.to_json(),
      },
    })
  }
  {
    "file": path.to_json(),
    "sha256": sha.to_json(),
    "origins": origins.length().to_json(),
    "gradient_norm": norm.to_json(),
    "predicted_change": (after - before).to_json(),
    "maximum_restore_error": maximum_restore_error.to_json(),
    "local_physical_change": (local_change / origins.length().to_double()).to_json(),
    "full_physical_change": (full_change / origins.length().to_double()).to_json(),
    "records": records.to_json(),
  }
}
