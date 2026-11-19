///|
fn field(value : Json, key : String) -> Json raise {
  guard value is Object(fields) && fields.get(key) is Some(v) else {
    fail("study field missing: " + key)
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
fn mode_for_window(window : Int32?) -> String {
  match window {
    Some(10) => "h10"
    Some(n) => "h" + n.to_string()
    None => "full"
  }
}

///|
async fn policy_path(base : String) -> String {
  if @fs.exists(base + ".moon.json") {
    base + ".moon.json"
  } else {
    base + ".pt"
  }
}

///|
fn offset_for_case(
  runtime : @native_physics.Runtime,
  case_json : Json,
  rng : @numeric.Rng,
) -> Array[Double]? raise {
  if text(case_json, "motion") != "pose_offset" {
    return None
  }
  let limits = field(case_json, "goal_offset_rad")
  Some(
    @native_physics.pose_offset(
      runtime.joint_names(),
      number(limits, "lower"),
      number(limits, "waist"),
      number(limits, "upper"),
      runtime.joint_names().map(_ => 2 * rng.uniform() - 1),
    ),
  )
}

///|
fn sines_for_case(
  runtime : @native_physics.Runtime,
  case_json : Json,
  rng : @numeric.Rng,
) -> @native_physics.JointSines? raise {
  if text(case_json, "motion") != "random_joint_sines" {
    return None
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
  Some({
    amplitude: amplitudes.map(a => a * (0.3 + 0.7 * rng.uniform())),
    bias: amplitudes.map(a => a * (0.4 * rng.uniform() - 0.2)),
    frequency_hz: amplitudes.map(_ => 0.15 + 0.5 * rng.uniform()),
    phase_rad: amplitudes.map(_ => {
      6.283185307179586 * rng.uniform() - 3.141592653589793
    }),
  })
}

///|
fn parent_runner(
  parent : @temporal.TemporalPolicy,
  dt : Double,
  reference : (Double) -> Array[Double],
) -> @temporal.TemporalRunner {
  @temporal.TemporalRunner::new(parent.temporal, dt, reference, (obs, goal) => {
    let tape = @numeric.Tape::new()
    parent.base
    .latent_mean(
      tape,
      parent.base.network.bind(tape),
      tape.vector(obs),
      tape.vector(goal),
    )
    .map(v => v.value)
  })
}

///|
struct EvaluationCell {
  episodes : Array[@native_physics.Episode]
  trials : Array[Json]
  maximum_feature_error : Double
  maximum_action_error : Double
  maximum_other_error : Double
}

///|
fn study_rollout(
  runtime : @native_physics.Runtime,
  parent : @temporal.TemporalPolicy,
  head : @balance.LearnedAnkleHead?,
  geometry : @balance.Kinematics,
  window : Int32?,
  case_json : Json,
  reset_seed : Int32,
  dt : Double,
  seconds : Double,
  fall_height : Double,
  fall_upright : Double,
) -> (@native_physics.Episode, @native_physics.Trial, Double, Double, Double) raise {
  let case : @native_physics.Case = @json.from_json(case_json)
  let rng = @numeric.Rng::new(reset_seed.to_uint())
  let offset = offset_for_case(runtime, case_json, rng)
  let schedule = sines_for_case(runtime, case_json, rng)
  runtime.reset(case.keyframe, case.friction)
  let initial = runtime.state()
  let nominal = runtime.q_indices().map(i => initial[i])
  let reference = fn(time : Double) -> Array[Double] {
    try! runtime.reference(nominal, case.motion, time, offset?, schedule?)
  }
  let temporal_runner = parent_runner(parent, dt, reference)
  let feedback_runner = head.map(h => {
    let policy : @balance_policy.BalancePolicy = {
      parent,
      head: @balance.Learned(h),
      geometry,
      dt,
      window,
    }
    policy.runner(reference)
  })
  let captured : Array[Array[Double]] = []
  let parent_actions : Array[Array[Double]] = []
  let predict = fn(obs : Array[Double], goal : Array[Double]) -> Array[Double] {
    match feedback_runner {
      Some(runner) => {
        let action = runner.predict(obs, goal)
        captured.push(runner.last_feature.unwrap().copy())
        parent_actions.push(runner.last_parent.unwrap().copy())
        action
      }
      None => temporal_runner.predict(obs, goal)
    }
  }
  let (episode, trial) = runtime.rollout(
    case,
    reset_seed,
    "policy",
    seconds,
    dt,
    () => rng.normal(),
    fall_height~,
    fall_upright~,
    policy=predict,
    offset?,
    schedule?,
  )
  let mut feature_error = 0.0
  let mut action_error = 0.0
  let mut other_error = 0.0
  if head is Some(head) {
    let offline = @balance.sequence_features(
      geometry,
      episode.steps.map(s => s.observation),
      dt,
      window,
      @balance.GravityGyro,
    )
    guard offline.length() == captured.length() else {
      fail("online/offline feature count differs")
    }
    for i in 0..<episode.steps.length() {
      for j in 0..<offline[i].length() {
        let difference = (offline[i][j] - captured[i][j]).abs()
        feature_error = feature_error.max(difference)
        guard difference <= 0.00002 + 0.0001 * offline[i][j].abs() else {
          fail("online/offline balance features differ")
        }
      }
      let step = episode.steps[i]
      let expected = head.predict(step.observation, step.goal, offline[i])
      for j in 0..<4 {
        let difference = (step.applied_action[head.indices[j]] - expected[j]).abs()
        action_error = action_error.max(difference)
        guard difference <= 0.00002 + 0.0001 * expected[j].abs() else {
          fail("online/offline learned ankle action differs")
        }
      }
      for j in 0..<head.nu {
        if head.indices.contains(j) {
          continue
        }
        let difference = (step.applied_action[j] - parent_actions[i][j]).abs()
        other_error = other_error.max(difference)
        guard difference == 0 else {
          fail("learned feedback changed a non-ankle parent channel")
        }
      }
    }
  }
  (episode, trial, feature_error, action_error, other_error)
}

///|
fn scope_summary(trials : Array[Json], scope : String) -> Json raise {
  let selected = []
  for trial in trials {
    if text(trial, "scope") == scope {
      selected.push(trial)
    }
  }
  @balance.summarize_recorded_trials(selected)
}

///|
fn evaluate_cell(
  runtime : @native_physics.Runtime,
  parent : @temporal.TemporalPolicy,
  head : @balance.LearnedAnkleHead?,
  geometry : @balance.Kinematics,
  window : Int32?,
  config : Json,
  experiment : Json,
  collection : Json,
  seed : Int32,
  mode : String,
) -> EvaluationCell raise {
  let episodes = []
  let trials : Array[Json] = []
  let mut feature_error = 0.0
  let mut action_error = 0.0
  let mut other_error = 0.0
  let conditions : Array[(Json, Int32, String)] = []
  let canonical_seeds : Array[Int32] = @json.from_json(
    field(config, "canonical_reset_seeds"),
  )
  for case in array(experiment, "cases") {
    for reset in canonical_seeds {
      conditions.push((case, reset, "canonical-development"))
    }
  }
  for case in array(collection, "cases") {
    conditions.push(
      (
        case,
        integer(config, "train_audit_seed_base") + 10000 * seed,
        "train-family-audit",
      ),
    )
  }
  for (case, reset, scope) in conditions {
    let (episode, trial, fe, ae, oe) = study_rollout(
      runtime,
      parent,
      head,
      geometry,
      window,
      case,
      reset,
      number(collection, "control_dt_s"),
      number(config, "duration_s"),
      number(config, "fall_height_m"),
      number(config, "fall_upright_z"),
    )
    let id = episode.id +
      "-learned-balance-" +
      seed.to_string() +
      "-" +
      mode +
      "-" +
      scope
    let episode = { ..episode, id, }
    let row = trial.to_json()
    match row {
      Object(fields) => {
        fields["episode_id"] = id.to_json()
        fields["scope"] = scope.to_json()
        ignore(fields.remove("replay"))
      }
      _ => ()
    }
    episodes.push(episode)
    trials.push(row)
    feature_error = feature_error.max(fe)
    action_error = action_error.max(ae)
    other_error = other_error.max(oe)
  }
  {
    episodes,
    trials,
    maximum_feature_error: feature_error,
    maximum_action_error: action_error,
    maximum_other_error: other_error,
  }
}
