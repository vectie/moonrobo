///|
fn teacher_rollout(
  runtime : @native_physics.Runtime,
  case_json : Json,
  reset : Int32,
  config : Json,
  dt : Double,
  parameters : @balance.FeedbackParameters,
) -> (@native_physics.Episode, Json) raise {
  let case : @native_physics.Case = @json.from_json(case_json)
  let rng = @numeric.Rng::new(reset.to_uint())
  let offset = offset_for_case(runtime, case_json, rng)
  let schedule = sines_for_case(runtime, case_json, rng)
  let teacher = @balance_native.NativeBalanceTeacher::new(
    runtime, parameters, dt,
  )
  let (episode, trial) = runtime.rollout(
    case,
    reset,
    "policy",
    number(config, "duration_s"),
    dt,
    () => rng.normal(),
    fall_height=number(config, "fall_height_m"),
    fall_upright=number(config, "fall_upright_z"),
    policy=(obs, goal) => try! teacher.predict(obs, goal),
    offset?,
    schedule?,
  )
  let row = trial.to_json()
  match row {
    Object(fields) => ignore(fields.remove("replay"))
    _ => ()
  }
  (episode, row)
}

///|
fn sustained_rollout(
  runtime : @native_physics.Runtime,
  policy : @balance_policy.BalancePolicy,
  case_json : Json,
  reset : Int32,
  config : Json,
  suffix : String,
) -> (@native_physics.Episode, Json, Json) raise {
  guard policy.head is Sustained(head) else {
    fail("sustained policy bundle required")
  }
  let case : @native_physics.Case = @json.from_json(case_json)
  let rng = @numeric.Rng::new(reset.to_uint())
  let offset = offset_for_case(runtime, case_json, rng)
  let schedule = sines_for_case(runtime, case_json, rng)
  runtime.reset(case.keyframe, case.friction)
  let initial = runtime.state()
  let nominal = runtime.q_indices().map(i => initial[i])
  let reference = fn(time : Double) -> Array[Double] {
    try! runtime.reference(nominal, case.motion, time, offset?, schedule?)
  }
  let runner = policy.runner(reference)
  let captured : Array[Array[Double]] = []
  let parent_actions : Array[Array[Double]] = []
  let predict = fn(obs : Array[Double], goal : Array[Double]) -> Array[Double] {
    let action = runner.predict(obs, goal)
    captured.push(runner.last_feature.unwrap().copy())
    parent_actions.push(runner.last_parent.unwrap().copy())
    action
  }
  let (episode, trial) = runtime.rollout(
    case,
    reset,
    "policy",
    number(config, "duration_s"),
    policy.dt,
    () => rng.normal(),
    fall_height=number(config, "fall_height_m"),
    fall_upright=number(config, "fall_upright_z"),
    policy=predict,
    offset?,
    schedule?,
  )
  let features = @balance.sequence_features(
    policy.geometry,
    episode.steps.map(s => s.observation),
    policy.dt,
    None,
    @balance.GravityGyro,
  )
  let indices = head.ankle.indices.copy()
  if head.control_waist {
    indices.push(head.waist_index)
  }
  let mut feature_error = 0.0
  let mut action_error = 0.0
  let mut other_error = 0.0
  for i in 0..<episode.steps.length() {
    let step = episode.steps[i]
    for j in 0..<features[i].length() {
      feature_error = feature_error.max((features[i][j] - captured[i][j]).abs())
    }
    let expected = head.predict(step.observation, step.goal, features[i])
    for j in 0..<indices.length() {
      action_error = action_error.max(
        (step.applied_action[indices[j]] - expected[j]).abs(),
      )
    }
    for j in 0..<head.ankle.nu {
      if !indices.contains(j) {
        other_error = other_error.max(
          (step.applied_action[j] - parent_actions[i][j]).abs(),
        )
      }
    }
  }
  guard feature_error <= number(config, "maximum_feature_alignment_error") &&
    action_error <= number(config, "maximum_action_alignment_error_rad") &&
    other_error == 0 else {
    fail(
      "sustained online/offline features, actions or frozen parent channels disagree",
    )
  }
  let id = episode.id + suffix
  let episode = { ..episode, id, }
  let trial = trial.to_json()
  match trial {
    Object(fields) => {
      fields["episode_id"] = id.to_json()
      ignore(fields.remove("replay"))
    }
    _ => ()
  }
  (
    episode,
    trial,
    {
      "feature_error": feature_error.to_json(),
      "action_error_rad": action_error.to_json(),
      "other_channel_error": other_error.to_json(),
    },
  )
}

///|
fn episode_record(
  runtime : @native_physics.Runtime,
  revision : String,
  dt : Double,
  episode : @native_physics.Episode,
  trial : Json,
  roles : Json,
) -> Json {
  let result : Json = {
    "dataset": runtime.dataset([episode], revision, dt~),
    "trials": [trial],
  }
  match (result, roles) {
    (Object(fields), Object(extra)) =>
      for key, value in extra {
        fields[key] = value
      }
    _ => ()
  }
  result
}

///|
fn selection_better(
  candidate : Json,
  candidate_coefficients : Int32,
  best : Json,
  best_coefficients : Int32,
) -> Bool raise {
  let cf = integer(candidate, "falls")
  let bf = integer(best, "falls")
  if cf != bf {
    return cf < bf
  }
  let cs = number(candidate, "mean_survival_s")
  let bs = number(best, "mean_survival_s")
  if cs != bs {
    return cs > bs
  }
  let ce = number(candidate, "mean_joint_rmse_rad")
  let be = number(best, "mean_joint_rmse_rad")
  if ce != be {
    return ce < be
  }
  candidate_coefficients < best_coefficients
}
