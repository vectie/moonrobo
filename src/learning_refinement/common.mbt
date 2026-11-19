///|
fn field(value : Json, key : String) -> Json raise {
  guard value is Object(fields) && fields.get(key) is Some(v) else {
    fail("missing refinement field: " + key)
  }
  v
}

///|
fn text(value : Json, key : String) -> String raise {
  @json.from_json(field(value, key))
}

///|
fn number(value : Json, key : String) -> Double raise {
  @json.from_json(field(value, key))
}

///|
fn integer(value : Json, key : String) -> Int32 raise {
  @json.from_json(field(value, key))
}

///|
fn array(value : Json, key : String) -> Array[Json] raise {
  @json.from_json(field(value, key))
}

///|
fn boolean(value : Json, key : String, fallback : Bool) -> Bool raise {
  guard value is Object(fields) else { fail("refinement object required") }
  match fields.get(key) {
    None => fallback
    Some(v) => @json.from_json(v)
  }
}

///|
async fn actor_path(directory : String, seed : Int32) -> String {
  let base = directory + "/actor-seed-" + seed.to_string()
  if @fs.exists(base + ".moon.json") {
    base + ".moon.json"
  } else {
    base + ".pt"
  }
}

///|
/// Model ancestry is carried from the actual incoming checkpoint, never
/// reconstructed from a new configuration or silently omitted.
async fn incoming_temporal_metadata(path : String) -> Json {
  let bytes = @fs.read_file(path).binary()
  if bytes.length() >= 4 && bytes[0:4] == b"PK\x03\x04" {
    let payload = @artifacts.decode_torch_checkpoint(bytes)
    {
      "model_ref": payload.field("model_ref").plain_json(),
      "base_config": payload.field("base_config").plain_json(),
    }
  } else {
    @artifacts.load_checkpoint(path, "temporal-actor").metadata
  }
}

///|
fn inherit_temporal_metadata(parent : Json, current : Json) -> Json raise {
  let model_ref = field(parent, "model_ref")
  let base_config = field(parent, "base_config")
  guard model_ref is String(identity) &&
    !identity.is_empty() &&
    base_config is Object(_) else {
    fail("incoming temporal checkpoint has no complete model/base ancestry")
  }
  guard current is Object(fields) else {
    fail("temporal metadata must be object")
  }
  let fields = fields.copy()
  fields["model_ref"] = model_ref
  fields["base_config"] = base_config
  fields["source_language"] = "moonbit"
  Json::object(fields)
}

///|
fn case_reference(
  runtime : @native_physics.Runtime,
  case_json : Json,
  episode : Json,
) -> ((Double) -> Array[Double]) raise {
  let nominal : Array[Double] = @json.from_json(
    field(episode, "reference_nominal_rad"),
  )
  let offset : Array[Double]? = match episode {
    Object(fields) =>
      match fields.get("reference_offset_rad") {
        Some(value) if value != Json::null() => Some(@json.from_json(value))
        _ => None
      }
    _ => None
  }
  let schedule : @native_physics.JointSines? = match episode {
    Object(fields) =>
      match fields.get("reference_schedule") {
        Some(value) if value != Json::null() => Some(@json.from_json(value))
        _ => None
      }
    _ => None
  }
  let motion = text(case_json, "motion")
  fn(time : Double) -> Array[Double] {
    try! runtime.reference(nominal, motion, time, offset?, schedule?)
  }
}

///|
fn replay_points(
  runtime : @native_physics.Runtime,
  raw : Array[Json],
  cases : Map[String, Json],
  actor : @temporal.TemporalPolicy,
  config : Json,
  finite_value : Bool,
) -> Array[@temporal.ValuePoint] raise {
  let points : Array[@temporal.ValuePoint] = []
  let horizon = integer(config, "horizon")
  let dt = 0.02
  for raw_episode in raw {
    let episode : @native_physics.Episode = @json.from_json(raw_episode)
    guard episode.split == "train" &&
      cases.get(episode.case_id) is Some(case_json) else {
      fail("actor replay contains held-out or undeclared case")
    }
    for i in 0..<(episode.steps.length() - 1) {
      guard !episode.steps[i].terminated && !episode.steps[i].truncated else {
        fail("actor replay crosses reset")
      }
    }
    let hlen = if finite_value { 10 } else { actor.temporal.history_length }
    let histories = @temporal.causal_history(
      episode.steps.map(s => s.observation),
      episode.steps.map(s => s.time_s),
      hlen,
      dt,
    )
    let reference = case_reference(runtime, case_json, raw_episode)
    for i in 0..<episode.steps.length() {
      let step = episode.steps[i]
      let remaining = if finite_value {
        number(config, "duration_s") - step.time_s
      } else {
        0.0
      }
      if finite_value && remaining < (horizon + 1).to_double() * dt {
        continue
      }
      let goal_count = horizon +
        (if finite_value { 10 } else { actor.temporal.future_length }) +
        1
      let goals = Array::makei(goal_count, j => {
        reference(step.time_s + j.to_double() * dt)
      })
      for j in 0..<step.goal.length() {
        guard (goals[0][j] - step.goal[j]).abs() < 0.00001 else {
          fail(
            "actor replay goal schedule disagrees with recorded current goal",
          )
        }
      }
      points.push({
        state: step.state,
        history: histories[i],
        goals,
        context: episode.context,
        remaining,
        target: 0.0,
      })
    }
  }
  guard !points.is_empty() else { fail("no valid actor replay points") }
  points
}

///|
fn goal_samplers(
  runtime : @native_physics.Runtime,
  case_json : Json,
  rng : @numeric.Rng,
) -> (Array[Double]?, @native_physics.JointSines?) raise {
  let motion = text(case_json, "motion")
  if motion != "pose_offset" && motion != "random_joint_sines" {
    return (None, None)
  }
  let limits = field(case_json, "goal_offset_rad")
  let amplitudes = runtime
    .joint_names()
    .map(name => {
      if name.has_prefix("waist_") {
        number(limits, "waist")
      } else if ["shoulder", "elbow", "wrist"].any(part => name.contains(part)) {
        number(limits, "upper")
      } else {
        number(limits, "lower")
      }
    })
  if motion == "pose_offset" {
    return (Some(amplitudes.map(a => a * (2 * rng.uniform() - 1))), None)
  }
  (
    None,
    Some({
      amplitude: amplitudes.map(a => a * (0.3 + 0.7 * rng.uniform())),
      bias: amplitudes.map(a => a * (0.4 * rng.uniform() - 0.2)),
      frequency_hz: amplitudes.map(_ => 0.15 + 0.5 * rng.uniform()),
      phase_rad: amplitudes.map(_ => {
        6.283185307179586 * rng.uniform() - 3.141592653589793
      }),
    }),
  )
}

///|
fn rollout(
  runtime : @native_physics.Runtime,
  actor : @temporal.TemporalPolicy,
  case_json : Json,
  reset : Int32,
  config : Json,
  dt : Double,
  snapshots : Map[Int32, Array[Double]],
  capture_steps : Array[Int32],
) -> (@native_physics.Episode, @native_physics.Trial, Json) raise {
  let case : @native_physics.Case = @json.from_json(case_json)
  let rng = @numeric.Rng::new(reset.to_uint())
  let (offset, schedule) = goal_samplers(runtime, case_json, rng)
  runtime.reset(case.keyframe, case.friction)
  let initial = runtime.state()
  let nominal = runtime.q_indices().map(i => initial[i])
  let reference = fn(time : Double) -> Array[Double] {
    try! runtime.reference(nominal, case.motion, time, offset?, schedule?)
  }
  let runner = @temporal.TemporalRunner::new(actor.temporal, dt, reference, (
    obs,
    goal,
  ) => {
    let tape = @numeric.Tape::new()
    actor.base
    .latent_mean(
      tape,
      actor.base.network.bind(tape),
      tape.vector(obs),
      tape.vector(goal),
    )
    .map(v => v.value)
  })
  let trace = fn(
    step : Int32,
    _action : Array[Double],
    _goal : Array[Double],
  ) -> Unit {
    if capture_steps.contains(step) {
      snapshots[step] = runtime.integration()
    }
  }
  let (episode, trial) = runtime.rollout(
    case,
    reset,
    "policy",
    number(config, "duration_s"),
    dt,
    () => rng.normal(),
    fall_height=number(config, "fall_height_m"),
    fall_upright=number(config, "fall_upright_z"),
    policy=(obs, goal) => runner.predict(obs, goal),
    offset?,
    schedule?,
    trace~,
  )
  let raw = episode.to_json()
  match raw {
    Object(fields) => {
      if offset is Some(v) {
        fields["reference_offset_rad"] = v.to_json()
      }
      if schedule is Some(v) {
        fields["reference_schedule"] = v.to_json()
      }
    }
    _ => ()
  }
  (episode, trial, raw)
}

///|
struct Evaluation {
  summary : @training.PhysicsSummary
  trials : Array[Json]
}

///|
fn evaluate(
  runtime : @native_physics.Runtime,
  actor : @temporal.TemporalPolicy,
  experiment : Json,
  seeds : Array[Int32],
  split : String,
) -> Evaluation raise {
  let trials : Array[Json] = []
  let mut falls = 0
  let mut survival_s = 0.0
  let mut joint_rmse_rad = 0.0
  for case_json in array(experiment, "cases") {
    if split != "all" && text(case_json, "split") != split {
      continue
    }
    for seed in seeds {
      let (_, trial, _) = rollout(
        runtime,
        actor,
        case_json,
        seed,
        experiment,
        number(experiment, "control_dt_s"),
        Map([]),
        [],
      )
      if trial.failed {
        falls += 1
      }
      survival_s += trial.simulated_seconds
      joint_rmse_rad += trial.joint_rmse_rad
      trials.push(trial.to_json())
    }
  }
  guard !trials.is_empty() else {
    fail("no refinement physics evaluation conditions")
  }
  {
    summary: {
      falls,
      survival_s: survival_s / trials.length().to_double(),
      joint_rmse_rad: joint_rmse_rad / trials.length().to_double(),
    },
    trials,
  }
}

///|
fn summary_json(s : @training.PhysicsSummary, trials? : Int32) -> Json {
  let fields : Map[String, Json] = {
    "falls": s.falls.to_json(),
    "mean_survival_s": s.survival_s.to_json(),
    "mean_joint_rmse_rad": s.joint_rmse_rad.to_json(),
  }
  if trials is Some(count) {
    fields["trials"] = count.to_json()
  }
  Json::object(fields)
}

///|
fn no_tail_objective(
  model : @training.Dynamics,
  actor : @temporal.TemporalPolicy,
  tape : @numeric.Tape,
  model_parameters : Array[@numeric.Value],
  actor_parameters : Array[@numeric.Value],
  point : @temporal.ValuePoint,
  config : @training.RolloutConfig,
) -> @numeric.Value {
  @temporal.temporal_imagination(
    tape,
    tape.vector(point.state),
    point.history.map(row => tape.vector(row)),
    point.goals.map(row => tape.vector(row)),
    tape.vector(point.context),
    config.horizon,
    actor.temporal.future_length,
    config.gamma,
    (history, goal, future) => {
      actor.forward(tape, actor_parameters, history, goal, future)
    },
    (state, action, context) => {
      model.forward(tape, model_parameters, state, action, context)
    },
    (state, action) => {
      @training.observation(tape, state, action, actor.base.body)
    },
    (state, action, previous, goal) => {
      @training.step_reward(
        tape,
        state,
        action,
        previous,
        goal,
        actor.base.body.q_indices,
        config.target_height,
      )
    },
    (_, _, _) => tape.scalar(0),
    false,
  ).total
}

///|
fn refinement_update(
  model : @training.Dynamics,
  actor : @temporal.TemporalPolicy,
  optimizer : @numeric.Adam,
  points : Array[@temporal.ValuePoint],
  config : @training.RolloutConfig,
) -> (Double, Double) {
  let tape = @numeric.Tape::new()
  let parameters = actor.parameters()
  let bound = tape.vector(parameters)
  let model_bound = model.network.bind(tape)
  let objective = tape.mean(
    points.map(p => {
      no_tail_objective(model, actor, tape, model_bound, bound, p, config)
    }),
  )
  let loss = tape.scale(objective, -1.0 / config.horizon.to_double())
  guard @numeric.finite(loss.value) else {
    abort("nonfinite temporal refinement objective")
  }
  tape.backward(loss)
  let norm = optimizer.step(parameters, tape, bound)
  actor.restore(parameters)
  (objective.value, norm)
}
