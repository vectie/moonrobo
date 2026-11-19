///|
fn field(value : Json, key : String) -> Json raise {
  guard value is Object(fields) && fields.get(key) is Some(result) else {
    fail("missing teacher study field: " + key)
  }
  result
}

///|
fn number(value : Json, key : String) -> Double raise {
  let result : Double = @json.from_json(field(value, key))
  guard @numeric.finite(result) else { fail("nonfinite teacher study number") }
  result
}

///|
fn cases(value : Json, train_only : Bool) -> Array[Json] raise {
  let all : Array[Json] = @json.from_json(field(value, "cases"))
  all.filter(fn(item) {
    if !train_only {
      true
    } else {
      match item {
        Object(fields) => fields.get("split") is Some(String("train"))
        _ => false
      }
    }
  })
}

///|
fn rank(summary : Json) -> (Double, Double, Double) raise {
  (
    -number(summary, "falls"),
    number(summary, "mean_survival_s"),
    -number(summary, "mean_joint_rmse_rad"),
  )
}

///|
pub fn trials_for(
  runtime : @native_physics.Runtime,
  case_specs : Array[Json],
  seeds : Array[Int32],
  parameters : Json?,
  seconds : Double,
  dt : Double,
  fall_height : Double,
  fall_upright : Double,
) -> (Array[@native_physics.Episode], Array[@native_physics.Trial], Json) raise {
  let episodes : Array[@native_physics.Episode] = []
  let trials : Array[@native_physics.Trial] = []
  for spec in case_specs {
    let case : @native_physics.Case = @json.from_json(spec)
    for seed in seeds {
      let teacher = match parameters {
        Some(p) =>
          Some(
            @balance_native.NativeBalanceTeacher::new(
              runtime,
              @balance_native.parameters_from_json(p),
              dt,
            ),
          )
        None => None
      }
      let rng = @numeric.Rng::new(seed.to_uint())
      let (offset, schedule) = @balance_native.sample_reference(
        runtime, spec, seed,
      )
      let policy = teacher.map(fn(teacher) {
        fn(obs, goal) { try! teacher.predict(obs, goal) }
      })
      let (episode, trial) = runtime.rollout(
        case,
        seed,
        if teacher.is_some() {
          "policy"
        } else {
          "position"
        },
        seconds,
        dt,
        fn() { rng.normal() },
        fall_height~,
        fall_upright~,
        policy?,
        offset?,
        schedule?,
      )
      episodes.push(episode)
      trials.push(trial)
    }
  }
  guard !trials.is_empty() else {
    fail("teacher study selected no cases/seeds")
  }
  (
    episodes,
    trials,
    @balance.summarize_recorded_trials(trials.map(fn(t) { t.to_json() })),
  )
}

///|
fn grid_candidates(fixed : Json, grid : Json) -> Array[Json] raise {
  guard fixed is Object(base) && grid is Object(fields) else {
    fail("teacher fixed/grid must be objects")
  }
  let mut candidates = [base.copy()]
  for name, values in fields {
    let values : Array[Double] = @json.from_json(values)
    guard !values.is_empty() else { fail("empty teacher grid axis") }
    let next : Array[Map[String, Json]] = []
    for candidate in candidates {
      for value in values {
        guard @numeric.finite(value) else { fail("nonfinite grid value") }
        let row = candidate.copy()
        row[name] = value.to_json()
        next.push(row)
      }
    }
    candidates = next
  }
  candidates.map(fn(values) { Json::object(values) })
}

///|
/// Original teacher fit/evaluate/collect/develop contract, using the native simulator and separate source-language/RNG provenance.
pub async fn run(
  library : String,
  scene : String,
  experiment_path : String,
  config_path : String,
  output : String,
  command : String,
  provider_source : String,
  teacher_path? : String,
  diagnostic_seed? : Int32,
  diagnostic_case? : String,
) -> Json {
  let experiment = @artifacts.load_json(experiment_path)
  let config = @artifacts.load_json(config_path)
  let runtime = @native_physics.Runtime::open(library, scene)
  let dt = number(experiment, "control_dt_s")
  let duration = number(experiment, "duration_s")
  let height = number(experiment, "fall_height_m")
  let upright = number(experiment, "fall_upright_z")
  if !@fs.exists(output) {
    @fs.mkdir(output, recursive=true)
  }
  let provider_sha = @artifacts.sha256(@fs.read_file(provider_source).binary())
  if command == "diagnose" {
    let defaults : Array[Int32] = @json.from_json(
      field(config, "development_seeds"),
    )
    guard !defaults.is_empty() else { fail("diagnosis needs a reset seed") }
    let reset_seed = diagnostic_seed.unwrap_or(defaults[0])
    let all = cases(experiment, true)
    let selected = all.filter(fn(value) {
      match value {
        Object(fields) =>
          match diagnostic_case {
            Some(name) => fields.get("id") is Some(String(id)) && id == name
            None => fields.get("motion") is Some(String("stand"))
          }
        _ => false
      }
    })
    guard !selected.is_empty() else { fail("no matching train diagnosis case") }
    let selected_case : @native_physics.Case = @json.from_json(selected[0])
    let parameters : @balance.FeedbackParameters = match teacher_path {
      Some(path) =>
        @balance_native.parameters_from_json(
          field(@artifacts.load_json(path), "parameters"),
        )
      None =>
        {
          angle_gain: 0.0,
          rate_gain: 0.0,
          com_gain: 0.0,
          velocity_gain: 0.0,
          pitch_bias: 0.0,
          joint_damping: 0.0,
          residual_bound: 0.3,
          hip_share: 0.0,
          waist_share: 0.0,
          waist_dynamic_only: false,
          support_gain: 0.0,
        }
    }
    let monitor = @balance_native.NativeBalanceTeacher::new(
      runtime, parameters, dt,
    )
    let rng = @numeric.Rng::new(reset_seed.to_uint())
    let measurements : Array[Json] = []
    let (nq, _, _, nu) = runtime.dimensions()
    let names = runtime.joint_names()
    let ankle : Array[Int32] = []
    for suffix in ["_ankle_pitch_joint", "_ankle_roll_joint"] {
      for i, name in names {
        if name.has_suffix(suffix) {
          ankle.push(i)
        }
      }
    }
    let policy = if teacher_path.is_some() {
      Some(fn(obs, goal) { try! monitor.predict(obs, goal) })
    } else {
      None
    }
    let trace = fn(step : Int32, action : Array[Double], goal : Array[Double]) {
      if step % 10 != 0 {
        return
      }
      let (rotation, feet, com) = try! monitor.measurements()
      let support = Array::makei(3, fn(j) { (feet[0][j] + feet[1][j]) / 2.0 })
      let error = [com[0] - support[0], com[1] - support[1], 0.0]
      let state = runtime.state()
      let q_indices = runtime.q_indices()
      measurements.push({
        "time_s": (step.to_double() * dt).to_json(),
        "height_m": runtime.root_height().to_json(),
        "upright_z": rotation[8].to_json(),
        "com_minus_support_m": error.to_json(),
        "root_angular_velocity": [state[nq + 3], state[nq + 4], state[nq + 5]].to_json(),
        "support_m": support.to_json(),
        "joint_error_rad": Array::makei(nu, fn(i) {
          state[q_indices[i]] - goal[i]
        }).to_json(),
        "ankle_residual_rad": ankle.map(fn(i) { action[i] - goal[i] }).to_json(),
        "applied_torque_nm": runtime.actuator_force().to_json(),
        "contacts": runtime.contacts().to_json(),
      })
    }
    let (offset, schedule) = @balance_native.sample_reference(
      runtime,
      selected[0],
      reset_seed,
    )
    let (_, trial) = runtime.rollout(
      selected_case,
      reset_seed,
      if policy.is_some() {
        "policy"
      } else {
        "position"
      },
      duration,
      dt,
      fn() { rng.normal() },
      fall_height=height,
      fall_upright=upright,
      policy?,
      offset?,
      schedule?,
      trace~,
    )
    let report : Json = {
      "trial": trial.to_json(),
      "measurements": measurements.to_json(),
      "joint_names": names.to_json(),
      "physical_execution_allowed": false,
      "source_language": "moonbit",
    }
    ignore(@artifacts.save_json(output + "/diagnosis.json", report))
    return report
  }
  if command == "fit" {
    let seeds : Array[Int32] = @json.from_json(
      field(config, "development_seeds"),
    )
    let train = cases(experiment, true)
    let (_, _, baseline) = trials_for(
      runtime,
      train,
      seeds,
      None,
      duration,
      dt,
      height,
      upright,
    )
    let candidates = grid_candidates(
      field(config, "fixed"),
      field(config, "grid"),
    )
    let rows : Array[Json] = []
    let mut selected = -1
    let mut best_rank = (-1.0 / 0.0, -1.0 / 0.0, -1.0 / 0.0)
    for i, p in candidates {
      let (_, _, summary) = trials_for(
        runtime,
        train,
        seeds,
        Some(p),
        duration,
        dt,
        height,
        upright,
      )
      rows.push({ "parameters": p, "summary": summary })
      let current = rank(summary)
      if selected < 0 || current > best_rank {
        selected = i
        best_rank = current
      }
    }
    guard selected >= 0 else { fail("empty teacher candidate grid") }
    let report : Json = {
      "format": "moonrobo.g1-balance-teacher.v1",
      "kind": "handcrafted-simulator-feedback",
      "config": config,
      "parameters": candidates[selected],
      "development": field(rows[selected], "summary"),
      "baseline": baseline,
      "candidates": rows.to_json(),
      "provider_sha256": provider_sha.to_json(),
      "provider_source": provider_source.to_json(),
      "experiment": experiment,
      "physical_execution_allowed": false,
      "source_language": "moonbit",
      "rng": "xorshift32/Box-Muller, not NumPy-equivalent",
    }
    ignore(@artifacts.save_json(output + "/report.json", report))
    return report
  }
  guard ["evaluate", "collect", "develop"].contains(command) &&
    teacher_path is Some(teacher_path) else {
    fail(
      "teacher command expects fit/evaluate/collect/develop and selected teacher path",
    )
  }
  let teacher = @artifacts.load_json(teacher_path)
  guard field(teacher, "provider_sha256") == provider_sha.to_json() else {
    fail("teacher provider source changed")
  }
  let seeds_key = if command == "evaluate" {
    "evaluation_seeds"
  } else if command == "develop" {
    "development_seeds"
  } else {
    "collection_seeds"
  }
  let seeds : Array[Int32] = @json.from_json(field(config, seeds_key))
  let selected_cases = cases(experiment, command != "evaluate")
  let (episodes, trials, summary) = trials_for(
    runtime,
    selected_cases,
    seeds,
    Some(field(teacher, "parameters")),
    duration,
    dt,
    height,
    upright,
  )
  let digest = @artifacts.sha256(@fs.read_file(teacher_path).binary())
  let report : Json = {
    "format": "moonrobo.g1-balance-teacher-evaluation.v1",
    "kind": "handcrafted-simulator-feedback",
    "teacher_sha256": digest.to_json(),
    "experiment": experiment,
    "summary": summary,
    "trials": trials.to_json(),
    "seeds": seeds.to_json(),
    "physical_execution_allowed": false,
    "source_language": "moonbit",
  }
  ignore(@artifacts.save_json(output + "/report.json", report))
  ignore(
    @artifacts.save_json(
      output + "/dataset.json",
      runtime.dataset(episodes, "moonbit-balance-teacher", dt~),
    ),
  )
  report
}

///|
/// Training-only long-horizon grid selection followed by separately logged canonical and training-family audit evaluations.
pub async fn run_long(
  library : String,
  scene : String,
  study : String,
  config_path : String,
  output : String,
  provider_source : String,
) -> Json {
  let original = @artifacts.load_json(study + "/teacher.json")
  let collection = @artifacts.load_json(study + "/collection.json")
  let experiment = @artifacts.load_json(study + "/experiment.json")
  let config = @artifacts.load_json(config_path)
  let provider_sha = @artifacts.sha256(@fs.read_file(provider_source).binary())
  guard field(original, "provider_sha256") == provider_sha.to_json() else {
    fail("selected teacher provider source changed")
  }
  let train = cases(collection, false)
  guard train.length() == 9 &&
    train.all(fn(c) {
      match c {
        Object(fields) => fields.get("split") is Some(String("train"))
        _ => false
      }
    }) else {
    fail("long teacher search requires the nine declared training cases only")
  }
  let seeds : Array[Int32] = @json.from_json(
    field(config, "training_reset_seeds"),
  )
  let duration = number(config, "duration_s")
  let dt = number(collection, "control_dt_s")
  let height = number(config, "fall_height_m")
  let upright = number(config, "fall_upright_z")
  let runtime = @native_physics.Runtime::open(library, scene)
  if !@fs.exists(output) {
    @fs.mkdir(output, recursive=true)
  }
  let report_sources = @report_contract.capture(output, [
    (
      "teacher_implementation_sha256", "src/learning_balance/physics/teacher.mbt",
    ),
    ("teacher_algorithm_sha256", "src/learning_balance/teacher.mbt"),
    ("provider_sha256", "src/learning_balance/teacher_study/study.mbt"),
    ("teacher_provider_sha256", provider_source),
    ("teacher_core_sha256", "src/learning_balance/teacher.mbt"),
  ])
  ignore(
    @artifacts.save_json(output + "/charter.json", {
      "config": config,
      "fit_study": study.to_json(),
    }),
  )
  let candidates = grid_candidates(
    field(original, "parameters"),
    field(config, "grid"),
  )
  let rows : Array[Json] = []
  let mut selected = -1
  let mut best_rank = (-1.0 / 0.0, -1.0 / 0.0, -1.0 / 0.0)
  for i, p in candidates {
    let (_, trials, summary) = trials_for(
      runtime,
      train,
      seeds,
      Some(p),
      duration,
      dt,
      height,
      upright,
    )
    let mut transitions = 0
    for trial in trials {
      transitions += trial.steps
    }
    rows.push({
      "index": i.to_json(),
      "parameters": p,
      "summary": summary,
      "trials": trials.to_json(),
      "actual_transitions": transitions.to_json(),
    })
    let current = rank(summary)
    if selected < 0 || current > best_rank {
      selected = i
      best_rank = current
    }
    ignore(
      @artifacts.save_json(output + "/parameter-search.json", {
        "config": config,
        "candidates": rows.to_json(),
        "selected_index": selected.to_json(),
        "selection_uses": "training cases and training_reset_seeds only",
      }),
    )
  }
  guard selected >= 0 else { fail("empty long teacher search") }
  let selected_parameters = candidates[selected]
  let search_sha = @artifacts.sha256(
    @fs.read_file(output + "/parameter-search.json").binary(),
  )
  let chosen : Json = {
    "format": "moonrobo.g1-balance-teacher.v1",
    "kind": "handcrafted-simulator-feedback",
    "parameters": selected_parameters,
    "provider_sha256": provider_sha.to_json(),
    "provider_source": provider_source.to_json(),
    "source_teacher_sha256": @artifacts.sha256(
      @fs.read_file(study + "/teacher.json").binary(),
    ).to_json(),
    "parameter_search_sha256": search_sha.to_json(),
    "selection": "thirty-second training-family grid only",
    "selected_index": selected.to_json(),
    "physical_execution_allowed": false,
    "source_language": "moonbit",
  }
  ignore(@artifacts.save_json(output + "/teacher.json", chosen))
  let canonical_seeds : Array[Int32] = @json.from_json(
    field(config, "canonical_reset_seeds"),
  )
  let audit_seeds : Array[Int32] = @json.from_json(
    field(config, "audit_reset_seeds"),
  )
  let canonical = cases(experiment, false)
  let logs : Array[Json] = []
  let evaluations : Array[Json] = []
  let pooled : Array[Json] = []
  for
    (role, p) in [
      ("original", field(original, "parameters")),
      ("selected", selected_parameters),
    ] {
    let groups : Array[(String, Array[Json], Array[Int32])] = [
      ("canonical-development", canonical, canonical_seeds),
    ]
    for seed in audit_seeds {
      groups.push(("training-family-audit", train, [seed]))
    }
    for (scope, cases, seeds) in groups {
      let (episodes, trials, summary) = trials_for(
        runtime,
        cases,
        seeds,
        Some(p),
        duration,
        dt,
        height,
        upright,
      )
      let episodes = episodes.map(fn(ep) {
        { ..ep, id: ep.id + "-" + role + "-" + scope, }
      })
      let trials = trials.mapi(fn(i, t) { { ..t, episode_id: episodes[i].id, } })
      let transitions = trials.fold(init=0, fn(total, t) { total + t.steps })
      logs.push({
        "role": role.to_json(),
        "scope": scope.to_json(),
        "reset_seeds": seeds.to_json(),
        "dataset": runtime.dataset(episodes, "moonbit-long-teacher", dt~),
        "trials": trials.to_json(),
      })
      evaluations.push({
        "role": role.to_json(),
        "scope": scope.to_json(),
        "reset_seeds": seeds.to_json(),
        "summary": summary,
        "trials": trials.to_json(),
        "episodes": episodes.length().to_json(),
        "transitions": transitions.to_json(),
      })
    }
  }
  for role in ["original", "selected"] {
    for scope in ["canonical-development", "training-family-audit"] {
      let trials : Array[Json] = []
      for row in evaluations {
        if field(row, "role") == role.to_json() &&
          field(row, "scope") == scope.to_json() {
          let items : Array[Json] = @json.from_json(field(row, "trials"))
          trials.append(items)
        }
      }
      pooled.push(
        @report_contract.pooled(trials, {
          "role": role.to_json(),
          "scope": scope.to_json(),
        }),
      )
    }
  }
  let log_sha = @artifacts.save_jsonl(
    output + "/evaluation-physics.jsonl.gz",
    logs,
  )
  let report : Json = {
    "format": "moonrobo.g1-balance-teacher-long-fit.v1",
    "config": config,
    "selected_index": selected.to_json(),
    "selected_parameters": selected_parameters,
    "parameter_search_sha256": search_sha.to_json(),
    "evaluation_log_sha256": log_sha.to_json(),
    "evaluations": evaluations.to_json(),
    "evaluation": evaluations.to_json(),
    "pooled": pooled.to_json(),
    "source_teacher_sha256": @artifacts.sha256(
      @fs.read_file(study + "/teacher.json").binary(),
    ).to_json(),
    "teacher_sha256": @artifacts.sha256(
      @fs.read_file(output + "/teacher.json").binary(),
    ).to_json(),
    "search_trials": rows
    .fold(init=0, fn(total, row) {
      let trials : Array[Json] = @json.from_json(field(row, "trials"))
      total + trials.length()
    })
    .to_json(),
    "search_transitions": rows
    .fold(init=0.0, fn(total, row) { total + number(row, "actual_transitions") })
    .to_json(),
    "learned_policy_qualified": false,
    "physical_execution_allowed": false,
    "release_qualified": false,
    "source_language": "moonbit",
    "parity_verified": false,
  }
  let report = @report_contract.attach(report, report_sources)
  ignore(@artifacts.save_json(output + "/report.json", report))
  report
}
