///|
pub(all) struct TrainingPoints {
  observations : Array[Array[Double]]
  goals : Array[Array[Double]]
  targets : Array[Array[Double]]
  features : Map[String, Array[Array[Double]]]
  sources : Array[Json]
}

///|
/// Privileged recorded states are read only after source-role and identity filtering.
pub fn train_points(
  runtime : @native_physics.Runtime,
  geometry : @balance.Kinematics,
  records : Array[Json],
  config : Json,
  collection : Json,
  parameters : @balance.FeedbackParameters,
) -> TrainingPoints raise {
  let allowed : Map[String, Json] = Map([])
  for case in array(collection, "cases") {
    if text(case, "split") == "train" {
      allowed[text(case, "id")] = case
    }
  }
  let windows : Array[Int32?] = @json.from_json(field(config, "windows"))
  guard text(config, "transport") == "gravity_gyro" else {
    fail(
      "learned balance policy bundle currently requires gravity_gyro transport",
    )
  }
  let features : Map[String, Array[Array[Double]]] = Map([])
  for window in windows {
    features[mode_for_window(window)] = []
  }
  let observations = []
  let goals = []
  let targets = []
  let sources : Array[Json] = []
  let identities : Map[String, Bool] = Map([])
  let source_modes : Array[String] = @json.from_json(
    field(config, "source_modes"),
  )
  for record in records {
    let mode = text(record, "mode")
    if !source_modes.contains(mode) {
      continue
    }
    let dataset = field(record, "dataset")
    let episodes = array(dataset, "episodes")
    let trials = array(record, "trials")
    guard episodes.length() == trials.length() else {
      fail("unaligned intervention source episodes/trials")
    }
    for i in 0..<episodes.length() {
      let episode : @native_physics.Episode = @json.from_json(episodes[i])
      let trial = trials[i]
      if text(trial, "scope") != text(config, "source_scope") ||
        episode.split != text(config, "source_split") {
        continue
      }
      guard allowed.get(episode.case_id) is Some(case) &&
        episode.case_id == text(trial, "case_id") else {
        fail("training point outside declared collection cases")
      }
      let suffix = "-policy-" +
        integer(record, "seed").to_string() +
        "-" +
        mode +
        "-" +
        text(trial, "scope")
      guard episode.id == text(trial, "episode_id") + suffix &&
        !identities.contains(episode.id) else {
        fail("duplicate or mismatched training source episode identity")
      }
      identities[episode.id] = true
      guard !episode.steps.is_empty() else {
        fail("empty training source episode")
      }
      for j in 0..<(episode.steps.length() - 1) {
        guard !episode.steps[j].terminated && !episode.steps[j].truncated else {
          fail("training source episode crosses reset")
        }
      }
      let teacher = @balance_native.NativeBalanceTeacher::new(
        runtime,
        parameters,
        number(collection, "control_dt_s"),
      )
      let obs = episode.steps.map(s => s.observation)
      for step in episode.steps {
        runtime.set_state(step.state)
        let target = teacher.predict(step.observation, step.goal)
        observations.push(step.observation)
        goals.push(step.goal)
        targets.push(target)
      }
      for window in windows {
        features[mode_for_window(window)].append(
          @balance.sequence_features(
            geometry,
            obs,
            number(collection, "control_dt_s"),
            window,
            @balance.GravityGyro,
          ),
        )
      }
      sources.push({
        "episode_id": episode.id.to_json(),
        "parent_seed": field(record, "seed"),
        "source_mode": mode.to_json(),
        "case_id": episode.case_id.to_json(),
        "family": field(case, "family"),
        "split": episode.split.to_json(),
        "scope": field(trial, "scope"),
        "points": obs.length().to_json(),
      })
    }
  }
  guard !sources.is_empty() else { fail("missing training source episodes") }
  { observations, goals, targets, features, sources, }
}

///|
/// Train-only deterministic ankle-head fitting, then paired multi-parent physical evaluation.
pub async fn run_learned_study(
  library : String,
  scene : String,
  config_path : String,
  collection_path : String,
  experiment_path : String,
  teacher_path : String,
  intervention_directory : String,
  policies_directory : String,
  output : String,
) -> Unit {
  let config = @artifacts.load_json(config_path)
  let collection = @artifacts.load_json(collection_path)
  let experiment = @artifacts.load_json(experiment_path)
  let teacher = @artifacts.load_json(teacher_path)
  let teacher_source = teacher_provider_source(teacher)
  let teacher_source_sha = @artifacts.sha256(
    @fs.read_file(teacher_source).binary(),
  )
  guard field(teacher, "provider_sha256") == teacher_source_sha.to_json() else {
    fail("training-label teacher fitted source changed")
  }
  let source = intervention_directory + "/intervention-physics.jsonl.gz"
  let intervention_report = @artifacts.load_json(
    intervention_directory + "/report.json",
  )
  let source_sha : String = @json.from_json(
    field(intervention_report, "physics_log_sha256"),
  )
  let records = @artifacts.load_jsonl(source, expected_sha256=source_sha)
  let runtime = @native_physics.Runtime::open(library, scene)
  let geometry = @balance_native.make_spec(runtime)
  if !@fs.exists(output) {
    @fs.mkdir(output)
  }
  if !@fs.exists(output + "/policy") {
    @fs.mkdir(output + "/policy")
  }
  let report_sources = @report_contract.capture(output, [
    (
      "teacher_implementation_sha256", "src/learning_balance/physics/teacher.mbt",
    ),
    ("teacher_algorithm_sha256", "src/learning_balance/teacher.mbt"),
    ("provider_sha256", "src/learning_studies/learned.mbt"),
    ("feature_provider_sha256", "src/learning_balance/history.mbt"),
    ("head_provider_sha256", "src/learning_balance/heads.mbt"),
    ("teacher_provider_sha256", teacher_source),
  ])
  let start_time = @async.now()
  let points = train_points(
    runtime,
    geometry,
    records,
    config,
    collection,
    @balance_native.parameters_from_json(field(teacher, "parameters")),
  )
  let sources_sha = @artifacts.save_json(
    output + "/training-sources.json",
    points.sources.to_json(),
  )
  ignore(@artifacts.save_json(output + "/experiment.json", experiment))
  ignore(@artifacts.save_json(output + "/config.json", config))
  ignore(@artifacts.save_json(output + "/collection.json", collection))
  ignore(@artifacts.save_json(output + "/teacher.json", teacher))
  ignore(
    @artifacts.save_json(output + "/charter.json", {
      "config": config,
      "incoming_policies": policies_directory.to_json(),
      "source_intervention": intervention_directory.to_json(),
      "teacher_provider_source": teacher_source.to_json(),
    }),
  )
  let (lower, upper) = runtime.control_bounds()
  let windows : Array[Int32?] = @json.from_json(field(config, "windows"))
  let heads : Map[String, @balance.LearnedAnkleHead] = Map([])
  let fits : Array[Json] = []
  for window in windows {
    let mode = mode_for_window(window)
    let head = @balance.LearnedAnkleHead::new(
      runtime.joint_names(),
      lower,
      upper,
      bound=number(config, "residual_bound_rad"),
    )
    let features = points.features[mode]
    let reports = head.fit(
      Array::makei(points.observations.length(), i => {
        head.inputs(points.observations[i], features[i])
      }),
      points.goals,
      points.targets,
      margin=number(config, "uncensored_margin_rad"),
    )
    let mut squared_error = 0.0
    let mut maximum_error = 0.0
    for i in 0..<points.observations.length() {
      let predicted = head.predict(
        points.observations[i],
        points.goals[i],
        features[i],
      )
      for j in 0..<4 {
        let d = predicted[j] - points.targets[i][head.indices[j]]
        squared_error += d * d
        maximum_error = maximum_error.max(d.abs())
      }
    }
    fits.push({
      "window": window.to_json(),
      "fit": reports.to_json(),
      "training_ankle_action_error": {
        "count": (points.observations.length() * 4).to_json(),
        "squared_error": squared_error.to_json(),
        "maximum_error": maximum_error.to_json(),
        "rmse": (squared_error / (points.observations.length() * 4).to_double())
        .sqrt()
        .to_json(),
      },
    })
    heads[mode] = head
  }
  let fit_seconds = (@async.now() - start_time).to_double() / 1000
  let seeds : Array[Int32] = @json.from_json(field(config, "seeds"))
  let rows : Array[Json] = []
  let log : Array[Json] = []
  for seed in seeds {
    let incoming = policy_path(
      policies_directory + "/actor-seed-" + seed.to_string(),
    )
    let parent_sha = @artifacts.sha256(@fs.read_file(incoming).binary())
    let parent = @temporal.load_temporal(incoming)
    let initial = parent.parameters()
    let conditions : Array[(String, Int32?)] = [("student", None)]
    for window in windows {
      conditions.push((mode_for_window(window), window))
    }
    for (mode, window) in conditions {
      let head = if mode == "student" { None } else { Some(heads[mode]) }
      let checkpoint = if mode == "student" {
        None
      } else {
        Some(
          output +
          "/policy/actor-" +
          mode +
          "-seed-" +
          seed.to_string() +
          ".moon.json",
        )
      }
      let checkpoint_sha = match checkpoint {
        Some(path) => {
          let policy : @balance_policy.BalancePolicy = {
            parent,
            head: @balance.Learned(head.unwrap()),
            geometry,
            dt: number(collection, "control_dt_s"),
            window,
          }
          let sha = @balance_policy.save(path, policy, {
            "parent_sha256": parent_sha.to_json(),
            "source_sha256": source_sha.to_json(),
            "training_sources_sha256": sources_sha.to_json(),
            "fit": "one shared deterministic head per window reused across frozen parents",
            "training_points": points.observations.length().to_json(),
          })
          let restored = @balance_policy.load(path)
          guard restored.parent.parameters() == initial &&
            restored.head.to_json() == policy.head.to_json() else {
            fail(
              "learned balance checkpoint round-trip changed frozen parent/head",
            )
          }
          Some(sha)
        }
        None => None
      }
      let cell = evaluate_cell(
        runtime, parent, head, geometry, window, config, experiment, collection,
        seed, mode,
      )
      log.push({
        "seed": seed.to_json(),
        "mode": mode.to_json(),
        "dataset": runtime.dataset(
          cell.episodes,
          text(collection, "source_revision"),
          dt=number(collection, "control_dt_s"),
        ),
        "trials": cell.trials.to_json(),
      })
      let mut transitions = 0
      for episode in cell.episodes {
        transitions += episode.steps.length()
      }
      rows.push({
        "seed": seed.to_json(),
        "mode": mode.to_json(),
        "window": window.to_json(),
        "parent_sha256": parent_sha.to_json(),
        "checkpoint": checkpoint.to_json(),
        "checkpoint_sha256": checkpoint_sha.to_json(),
        "episodes": cell.episodes.length().to_json(),
        "transitions": transitions.to_json(),
        "trials": cell.trials.to_json(),
        "summaries": {
          "canonical-development": scope_summary(
            cell.trials,
            "canonical-development",
          ),
          "train-family-audit": scope_summary(cell.trials, "train-family-audit"),
        },
        "maximum_online_offline_feature_error": cell.maximum_feature_error.to_json(),
        "maximum_online_offline_action_error": cell.maximum_action_error.to_json(),
        "maximum_other_channel_error": cell.maximum_other_error.to_json(),
      })
      guard parent.parameters() == initial else {
        fail("evaluation changed frozen parent")
      }
    }
  }
  let pooled : Array[Json] = []
  let modes = ["student"]
  for window in windows {
    modes.push(mode_for_window(window))
  }
  for mode in modes {
    for scope in ["canonical-development", "train-family-audit"] {
      let trials = []
      for row in rows {
        if text(row, "mode") == mode {
          for trial in array(row, "trials") {
            if text(trial, "scope") == scope {
              trials.push(trial)
            }
          }
        }
      }
      pooled.push(
        @report_contract.pooled(trials, {
          "mode": mode.to_json(),
          "scope": scope.to_json(),
        }),
      )
    }
  }
  let log_sha = @artifacts.save_jsonl(
    output + "/evaluation-physics.jsonl.gz",
    log,
  )
  let report : Json = {
    "format": "moonrobo.moonbit-learned-balance-study.v1",
    "config": config,
    "fits": fits.to_json(),
    "fit_seconds": fit_seconds.to_json(),
    "wall_seconds": ((@async.now() - start_time).to_double() / 1000).to_json(),
    "training_episodes": points.sources.length().to_json(),
    "training_points": points.observations.length().to_json(),
    "independently_fitted_heads": windows.length().to_json(),
    "independent_parent_actors": seeds.length().to_json(),
    "source_sha256": source_sha.to_json(),
    "training_sources_sha256": sources_sha.to_json(),
    "evaluation_log_sha256": log_sha.to_json(),
    "evaluation": rows.to_json(),
    "pooled": pooled.to_json(),
    "release_qualified": false,
    "physical_execution_allowed": false,
    "parity_status": "awaiting-python-comparison",
  }
  ignore(
    @artifacts.save_json(
      output + "/report.json",
      @report_contract.attach(report, report_sources),
    ),
  )
}
