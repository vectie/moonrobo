///|
struct Segment {
  mut points : Int32
  mut saturated : Int32
  mut oracle_saturated : Int32
  action_squared : Map[String, Double]
  mut velocity_squared : Double
  mut feature_points : Int32
}

///|
pub async fn prior_learned(
  fit : String,
  long_folder : String,
) -> Map[(Int32, String, Int32), Array[Json]] {
  let result : Map[(Int32, String, Int32), Array[Json]] = {}
  for
    (folder, scope) in [
      (long_folder, "thirty-second-development"),
      (fit, "train-family-audit"),
    ] {
    let report = @artifacts.load_json(folder + "/report.json")
    let digest : String = @json.from_json(
      field(report, "evaluation_log_sha256"),
    )
    for
      row in @artifacts.load_jsonl(
        folder + "/evaluation-physics.jsonl.gz",
        expected_sha256=digest,
      ) {
      if field(row, "mode") != "full" {
        continue
      }
      let episodes : Array[Json] = @json.from_json(
        field(field(row, "dataset"), "episodes"),
      )
      let trials : Array[Json] = @json.from_json(field(row, "trials"))
      guard episodes.length() == trials.length() else {
        fail("prior learned episodes/trials differ")
      }
      let parent_seed : Int32 = @json.from_json(field(row, "seed"))
      for i, trial in trials {
        let case_id : String = @json.from_json(field(trial, "case_id"))
        let trial_scope : String = @json.from_json(field(trial, "scope"))
        let wanted = trial_scope == scope &&
          (if folder == long_folder {
            case_id == "wave"
          } else {
            case_id.has_prefix("joint-sines-")
          })
        if wanted {
          let reset : Int32 = @json.from_json(field(trial, "seed"))
          guard field(episodes[i], "id") == field(trial, "episode_id") else {
            fail("prior learned trial identity differs")
          }
          result[(parent_seed, case_id, reset)] = @json.from_json(
            field(episodes[i], "steps"),
          )
        }
      }
    }
  }
  result
}

///|
pub fn probe_long(
  runtime : @native_physics.Runtime,
  policy : @balance_policy.BalancePolicy?,
  raw_case : Json,
  reset : Int32,
  mode : String,
  config : Json,
  parameters : @balance.FeedbackParameters,
  dt : Double,
) -> (@native_physics.Episode, @native_physics.Trial, Json) raise {
  let case : @native_physics.Case = @json.from_json(raw_case)
  let teacher = @balance_native.NativeBalanceTeacher::new(
    runtime, parameters, dt,
  )
  let groups = @balance.joint_groups(runtime.joint_names())
  let (lower, upper) = runtime.control_bounds()
  let (offset, schedule) = @balance_native.sample_reference(
    runtime, raw_case, reset,
  )
  let mut nominal : Array[Double] = []
  let runner = policy.map(fn(p) {
    p.runner(fn(time) {
      try! runtime.reference(nominal, case.motion, time, offset?, schedule?)
    })
  })
  let history = policy.map(fn(p) {
    @balance.BalanceHistory::full_memory(p.geometry, dt)
  })
  let segments : Map[String, Segment] = {}
  let measurements : Array[Json] = []
  let mut last : Json = Json::null()
  let mut index = 0
  let stride = number(config, "diagnostic_stride").to_int()
  guard stride > 0 else { fail("positive long diagnostic stride required") }
  let predict = fn(obs : Array[Double], goal : Array[Double]) -> Array[Double] {
    if nominal.is_empty() {
      nominal = Array::makei(goal.length(), fn(i) { obs[i] })
    }
    let oracle = try! teacher.predict(obs, goal)
    let (rotation, feet, com) = try! teacher.measurements()
    let inverse = @balance.transpose(rotation)
    let (error, velocity) = teacher.memory()
    let local_error = @balance.matvec(inverse, error.unwrap())
    let local_velocity = @balance.matvec(inverse, velocity)
    let mut action = oracle
    let mut feature_json : Json = Json::null()
    let mut learned_json : Json = Json::null()
    let mut derived_json : Json = Json::null()
    let phase = if index.to_double() * dt < 10.0 {
      "first-ten-seconds"
    } else {
      "after-ten-seconds"
    }
    if !segments.contains(phase) {
      segments[phase] = {
        points: 0,
        saturated: 0,
        oracle_saturated: 0,
        action_squared: {
          "parent_ankle": 0.0,
          "derived_ankle": 0.0,
          "learned_ankle": 0.0,
          "parent_other": 0.0,
        },
        velocity_squared: 0.0,
        feature_points: 0,
      }
    }
    let stats = segments[phase]
    stats.points += 1
    if policy is Some(p) {
      let corrected = runner.unwrap().predict(obs, goal)
      let parent_action = runner.unwrap().last_parent
      // Preserve the unmodified parent action exposed by the complete runner.
      let parent_action = parent_action.unwrap_or(corrected)
      let feature = history.unwrap().observe(obs)
      let learned = match p.head {
        Learned(h) => h.predict(obs, goal, feature)
        _ => abort("long intervention expects v1 learned ankle head")
      }
      let derived = @balance.observation_ankle_feedback(
        parameters,
        p.geometry.nu,
        groups["ankle"],
        lower,
        upper,
        obs,
        goal,
        feature,
      )
      action = parent_action.copy()
      match mode {
        "learned_full" =>
          for j in 0..<groups["ankle"].length() {
            action[groups["ankle"][j]] = learned[j]
          }
        "derived_fixed_ankle" =>
          for j in 0..<groups["ankle"].length() {
            action[groups["ankle"][j]] = derived[j]
          }
        "oracle_ankle" =>
          action = @balance.blend_actions(action, oracle, groups["ankle"])
        "oracle_ankle_waist" =>
          action = @balance.blend_actions(action, oracle, groups["ankle_waist"])
        "oracle_lower" =>
          action = @balance.blend_actions(action, oracle, groups["lower"])
        _ => abort("unknown long intervention mode")
      }
      for
        (key, actual) in [
          ("parent_ankle", groups["ankle"].map(fn(i) { parent_action[i] })),
          ("derived_ankle", derived),
          ("learned_ankle", learned),
        ] {
        for j in 0..<actual.length() {
          let d = actual[j] - oracle[groups["ankle"][j]]
          stats.action_squared[key] += d * d
        }
      }
      for j in 0..<parent_action.length() {
        if !groups["ankle"].contains(j) {
          let d = parent_action[j] - oracle[j]
          stats.action_squared["parent_other"] += d * d
        }
      }
      for j in 0..<3 {
        let d = feature[3 + j] - local_velocity[j]
        stats.velocity_squared += d * d
      }
      stats.feature_points += 1
      feature_json = feature.to_json()
      learned_json = learned.to_json()
      derived_json = derived.to_json()
    }
    for j in groups["ankle"] {
      if (action[j] - goal[j]).abs() >= parameters.residual_bound - 2.0e-6 {
        stats.saturated += 1
      }
      if (oracle[j] - goal[j]).abs() >= parameters.residual_bound - 2.0e-6 {
        stats.oracle_saturated += 1
      }
    }
    let group_errors : Map[String, Double] = {}
    for group, ids in groups {
      let mut squared = 0.0
      for j in ids {
        let d = obs[j] - goal[j]
        squared += d * d
      }
      group_errors[group] = (squared / ids.length().to_double()).sqrt()
    }
    let waist = groups["ankle_waist"][groups["ankle_waist"].length() - 1]
    last = {
      "step": index.to_json(),
      "time_s": (index.to_double() * dt).to_json(),
      "root_height_m": runtime.root_height().to_json(),
      "upright_z": rotation[8].to_json(),
      "local_com_error_m": local_error.to_json(),
      "true_filtered_velocity_m_s": local_velocity.to_json(),
      "foot_site_height_m": feet.map(fn(f) { f[2] }).to_json(),
      "support_m": Array::makei(3, fn(j) { (feet[0][j] + feet[1][j]) / 2.0 }).to_json(),
      "contacts": runtime.contacts().to_json(),
      "actual_ankle": groups["ankle"].map(fn(j) { action[j] }).to_json(),
      "oracle_ankle": groups["ankle"].map(fn(j) { oracle[j] }).to_json(),
      "actual_waist_pitch": [action[waist]].to_json(),
      "oracle_waist_pitch": [oracle[waist]].to_json(),
      "joint_rmse_by_group_rad": group_errors.to_json(),
      "observation_feature": feature_json,
      "derived_ankle": derived_json,
      "learned_ankle": learned_json,
    }
    if index % stride == 0 {
      measurements.push(last)
    }
    index += 1
    action
  }
  let rng = @numeric.Rng::new(reset.to_uint())
  let (episode, trial) = runtime.rollout(
    case,
    reset,
    "policy",
    number(config, "duration_s"),
    dt,
    fn() { rng.normal() },
    fall_height=number(config, "fall_height_m"),
    fall_upright=number(config, "fall_upright_z"),
    policy=predict,
    offset?,
    schedule?,
  )
  if (index - 1) % stride != 0 {
    measurements.push(last)
  }
  let finalized : Map[String, Json] = {}
  for phase, stats in segments {
    let fields : Map[String, Json] = {
      "points": stats.points.to_json(),
      "ankle_saturated": stats.saturated.to_json(),
      "oracle_ankle_saturated": stats.oracle_saturated.to_json(),
      "feature_points": stats.feature_points.to_json(),
      "ankle_saturation_fraction": (stats.saturated.to_double() /
      (4 * stats.points).to_double()).to_json(),
      "oracle_ankle_saturation_fraction": (stats.oracle_saturated.to_double() /
      (4 * stats.points).to_double()).to_json(),
    }
    if stats.feature_points > 0 {
      let rms : Map[String, Double] = {}
      for key, squared in stats.action_squared {
        rms[key] = (squared /
        (stats.feature_points * (if key == "parent_other" { 25 } else { 4 })).to_double()).sqrt()
      }
      fields["action_rmse_rad"] = rms.to_json()
      fields["velocity_rmse_m_s"] = (stats.velocity_squared /
        (3 * stats.feature_points).to_double())
        .sqrt()
        .to_json()
    }
    finalized[phase] = Json::object(fields)
  }
  (
    episode,
    trial,
    { "segments": finalized.to_json(), "measurements": measurements.to_json() },
  )
}

///|
/// Long interventions retain first-ten-second/tail segments and require every predeclared learned prefix to match recorded physics, excluding only the terminal truncation marker.
pub async fn run_long(
  library : String,
  scene : String,
  config_path : String,
  fit : String,
  long_folder : String,
  provider_source : String,
  output : String,
) -> Json {
  let config = @artifacts.load_json(config_path)
  let experiment = @artifacts.load_json(fit + "/experiment.json")
  let collection = @artifacts.load_json(fit + "/collection.json")
  let teacher = @artifacts.load_json(fit + "/teacher.json")
  let provider_sha = @artifacts.sha256(@fs.read_file(provider_source).binary())
  guard field(teacher, "provider_sha256") == provider_sha.to_json() else {
    fail("long intervention teacher implementation changed")
  }
  let parameters = @balance_native.parameters_from_json(
    field(teacher, "parameters"),
  )
  let prior = prior_learned(fit, long_folder)
  let canonical : Array[Json] = @json.from_json(field(experiment, "cases"))
  let train : Array[Json] = @json.from_json(field(collection, "cases"))
  let wave = canonical.filter(fn(c) {
    match c {
      Object(fields) => fields.get("id") is Some(String("wave"))
      _ => false
    }
  })
  let sines = train.filter(fn(c) {
    match c {
      Object(fields) =>
        fields.get("motion") is Some(String("random_joint_sines"))
      _ => false
    }
  })
  guard prior.length() == 15 && wave.length() == 1 && sines.length() == 3 else {
    fail("missing predeclared prior wave/sine conditions")
  }
  let seeds : Array[Int32] = @json.from_json(field(config, "seeds"))
  let modes : Array[String] = @json.from_json(field(config, "modes"))
  let wave_seeds : Array[Int32] = @json.from_json(
    field(config, "wave_reset_seeds"),
  )
  let dt = number(experiment, "control_dt_s")
  let runtime = @native_physics.Runtime::open(library, scene)
  if !@fs.exists(output) {
    @fs.mkdir(output, recursive=true)
  }
  let report_sources = @report_contract.capture(output, [
    (
      "teacher_implementation_sha256", "src/learning_balance/physics/teacher.mbt",
    ),
    ("teacher_algorithm_sha256", "src/learning_balance/teacher.mbt"),
    ("provider_sha256", "src/learning_balance/intervention/long.mbt"),
    ("teacher_provider_sha256", provider_source),
  ])
  let rows : Array[Json] = []
  let logs : Array[Json] = []
  let mut repeated = 0
  let seed_options = seeds.map(fn(seed) { Some(seed) })
  seed_options.push(None)
  for seed in seed_options {
    let policy : @balance_policy.BalancePolicy? = match seed {
      Some(seed) => {
        let native = fit +
          "/policy/actor-full-seed-" +
          seed.to_string() +
          ".moon.json"
        let path = if @fs.exists(native) {
          native
        } else {
          fit + "/policy/actor-full-seed-" + seed.to_string() + ".pt"
        }
        let p = @balance_policy.load(path)
        guard p.window.is_none() else {
          fail("long intervention expects full causal memory head")
        }
        Some(p)
      }
      None => None
    }
    let initial : Json = match policy {
      Some(p) => p.checkpoint(Json::null()).to_json()
      None => Json::null()
    }
    let evaluated_modes = if seed.is_none() { ["teacher_all"] } else { modes }
    let conditions : Array[(Json, Int32, Int32?)] = []
    for reset in wave_seeds {
      conditions.push((wave[0], reset, seed))
    }
    let context_seeds = match seed {
      Some(s) => [s]
      None => seeds
    }
    for parent_seed in context_seeds {
      for case in sines {
        conditions.push(
          (
            case,
            number(config, "sine_reset_seed_base").to_int() +
            10000 * parent_seed,
            Some(parent_seed),
          ),
        )
      }
    }
    for mode in evaluated_modes {
      let episodes : Array[@native_physics.Episode] = []
      let trials : Array[Json] = []
      let diagnostics : Array[Json] = []
      let segments : Array[Json] = []
      for (case, reset, context_parent) in conditions {
        let (episode, trial, diagnostic) = probe_long(
          runtime, policy, case, reset, mode, config, parameters, dt,
        )
        if mode == "learned_full" {
          let old = prior[(seed.unwrap(), episode.case_id, reset)]
          guard episode.steps.length() >= old.length() else {
            fail("shadow probes shortened original learned episode")
          }
          for i, recorded in old {
            guard recorded is Object(fields) &&
              episode.steps[i].to_json() is Object(actual) else {
              fail("invalid prior transition")
            }
            for key, value in fields {
              if key != "truncated" {
                guard actual.get(key) == Some(value) else {
                  fail(
                    "shadow probes changed recorded learned physics field: " +
                    key,
                  )
                }
              }
            }
          }
          repeated += 1
        }
        let scope = if episode.case_id == "wave" {
          "wave-development"
        } else {
          "sine-training-family-audit"
        }
        let label = match seed {
          Some(s) => s.to_string()
          None => "None"
        }
        let ident = episode.id + "-long-intervention-" + label + "-" + mode
        let episode : @native_physics.Episode = { ..episode, id: ident, }
        let fields : Map[String, Json] = match trial.to_json() {
          Object(fields) => fields.copy()
          _ => abort("trial is not an object")
        }
        fields["episode_id"] = ident.to_json()
        fields["scope"] = scope.to_json()
        fields["context_parent_seed"] = context_parent.to_json()
        episodes.push(episode)
        trials.push(Json::object(fields))
        diagnostics.push(diagnostic)
        segments.push({
          "case_id": trial.case_id.to_json(),
          "seed": trial.seed.to_json(),
          "scope": scope.to_json(),
          "segments": field(diagnostic, "segments"),
        })
      }
      let summaries : Map[String, Json] = {}
      for scope in ["wave-development", "sine-training-family-audit"] {
        let selected = trials.filter(fn(t) {
          match t {
            Object(fields) => fields.get("scope") == Some(scope.to_json())
            _ => false
          }
        })
        summaries[scope] = @balance.summarize_recorded_trials(selected)
      }
      logs.push({
        "seed": seed.to_json(),
        "mode": mode.to_json(),
        "dataset": runtime.dataset(episodes, "moonbit-long-intervention", dt~),
        "trials": trials.to_json(),
        "diagnostics": diagnostics.to_json(),
      })
      ignore(
        @artifacts.save_jsonl(output + "/intervention-physics.jsonl.gz", logs),
      )
      let mut transitions = 0
      for episode in episodes {
        transitions += episode.steps.length()
      }
      let digest : Json = match seed {
        Some(s) => {
          let native = fit +
            "/policy/actor-full-seed-" +
            s.to_string() +
            ".moon.json"
          let path = if @fs.exists(native) {
            native
          } else {
            fit + "/policy/actor-full-seed-" + s.to_string() + ".pt"
          }
          @artifacts.sha256(@fs.read_file(path).binary()).to_json()
        }
        None => Json::null()
      }
      rows.push({
        "seed": seed.to_json(),
        "mode": mode.to_json(),
        "episodes": episodes.length().to_json(),
        "transitions": transitions.to_json(),
        "summaries": summaries.to_json(),
        "trials": trials.to_json(),
        "segments": segments.to_json(),
        "checkpoint_sha256": digest,
      })
      if policy is Some(p) {
        guard p.checkpoint(Json::null()).to_json() == initial else {
          fail("long intervention mutated frozen actor/head/normalization")
        }
      }
    }
  }
  let pooled : Array[Json] = []
  let pooled_modes = modes.copy()
  pooled_modes.push("teacher_all")
  for mode in pooled_modes {
    for scope in ["wave-development", "sine-training-family-audit"] {
      let trials : Array[Json] = []
      for row in rows {
        if field(row, "mode") != mode.to_json() {
          continue
        }
        let all : Array[Json] = @json.from_json(field(row, "trials"))
        for trial in all {
          if field(trial, "scope") == scope.to_json() {
            trials.push(trial)
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
  let report : Json = {
    "format": "moonrobo.g1-balance-long-intervention.v1",
    "config": config,
    "rows": rows.to_json(),
    "pooled": pooled.to_json(),
    "exact_prior_learned_episodes": repeated.to_json(),
    "actor_and_head_unchanged": true,
    "fit_report_sha256": @artifacts.sha256(
      @fs.read_file(fit + "/report.json").binary(),
    ).to_json(),
    "long_report_sha256": @artifacts.sha256(
      @fs.read_file(long_folder + "/report.json").binary(),
    ).to_json(),
    "teacher_sha256": @artifacts.sha256(
      @fs.read_file(fit + "/teacher.json").binary(),
    ).to_json(),
    "teacher_provider_sha256": provider_sha.to_json(),
    "physics_log_sha256": @artifacts.sha256(
      @fs.read_file(output + "/intervention-physics.jsonl.gz").binary(),
    ).to_json(),
    "learned_policy_qualified": false,
    "physical_execution_allowed": false,
    "source_language": "moonbit",
  }
  let report = @report_contract.attach(report, report_sources)
  ignore(@artifacts.save_json(output + "/report.json", report))
  report
}
