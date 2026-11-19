///|
pub struct WindowTeacher {
  teacher : @balance_native.NativeBalanceTeacher
  frames : Int32
  dt : Double
  errors : Array[Array[Double]]
}

///|
pub fn WindowTeacher::new(
  runtime : @native_physics.Runtime,
  parameters : @balance.FeedbackParameters,
  frames : Int32,
  dt : Double,
) -> WindowTeacher raise {
  guard frames > 0 else { fail("teacher memory requires positive frame count") }
  {
    teacher: @balance_native.NativeBalanceTeacher::new(runtime, parameters, dt),
    frames,
    dt,
    errors: [],
  }
}

///|
pub fn WindowTeacher::predict(
  self : WindowTeacher,
  obs : Array[Double],
  goal : Array[Double],
) -> Array[Double] raise {
  let (_, feet, com) = self.teacher.measurements()
  let error = [
    com[0] - (feet[0][0] + feet[1][0]) / 2.0,
    com[1] - (feet[0][1] + feet[1][1]) / 2.0,
    0.0,
  ]
  let velocity = [0.0, 0.0, 0.0]
  for i in 1..<self.errors.length() {
    for j in 0..<3 {
      velocity[j] = 0.8 * velocity[j] +
        0.2 * (self.errors[i][j] - self.errors[i - 1][j]) / self.dt
    }
  }
  let last = if self.errors.is_empty() {
    None
  } else {
    Some(self.errors[self.errors.length() - 1])
  }
  self.teacher.set_memory(last, velocity)
  let action = self.teacher.predict(obs, goal)
  self.errors.push(error)
  while self.errors.length() > self.frames - 1 {
    self.errors.remove(0) |> ignore
  }
  action
}

///|
pub fn WindowTeacher::velocity(self : WindowTeacher) -> Array[Double] {
  self.teacher.memory().1
}

///|
fn field(value : Json, name : String) -> Json raise {
  guard value is Object(fields) && fields.get(name) is Some(result) else {
    fail("missing intervention field: " + name)
  }
  result
}

///|
fn number(value : Json, name : String) -> Double raise {
  @json.from_json(field(value, name))
}

///|
pub fn probe_trial(
  runtime : @native_physics.Runtime,
  actor : @temporal.TemporalPolicy,
  raw_case : Json,
  reset_seed : Int32,
  mode : String,
  config : Json,
  parameters : @balance.FeedbackParameters,
  dt : Double,
) -> (@native_physics.Episode, @native_physics.Trial, Json) raise {
  let case : @native_physics.Case = @json.from_json(raw_case)
  let full = @balance_native.NativeBalanceTeacher::new(runtime, parameters, dt)
  let windows : Map[String, WindowTeacher] = {}
  for n in [1, 10, 50] {
    windows[n.to_string()] = WindowTeacher::new(runtime, parameters, n, dt)
  }
  let groups = @balance.joint_groups(runtime.joint_names())
  let (_, _, _, nu) = runtime.dimensions()
  let errors : Map[String, Array[Double]] = {}
  for name in ["student", "1", "10", "50"] {
    errors[name] = Array::make(nu, 0.0)
  }
  let velocity_error : Map[String, Double] = { "1": 0.0, "10": 0.0, "50": 0.0 }
  let measurements : Array[Json] = []
  let mut last_measurement : Json = Json::null()
  let mut count = 0
  let mut nominal : Array[Double] = []
  let (offset, schedule) = @balance_native.sample_reference(
    runtime, raw_case, reset_seed,
  )
  let runner = @temporal.TemporalRunner::new(
    actor.temporal,
    dt,
    fn(time) {
      try! runtime.reference(nominal, case.motion, time, offset?, schedule?)
    },
    fn(obs, goal) {
      let tape = @numeric.Tape::new()
      actor.base
      .latent_mean(
        tape,
        actor.base.network.bind(tape),
        tape.vector(obs),
        tape.vector(goal),
      )
      .map(fn(v) { v.value })
    },
  )
  let predict = fn(obs : Array[Double], goal : Array[Double]) -> Array[Double] {
    if nominal.is_empty() {
      nominal = Array::makei(nu, fn(i) { obs[i] })
    }
    let student = runner.predict(obs, goal)
    let teacher = try! full.predict(obs, goal)
    let alternatives : Map[String, Array[Double]] = {}
    for name, window in windows {
      alternatives[name] = try! window.predict(obs, goal)
    }
    for j in 0..<nu {
      let d = student[j] - teacher[j]
      errors["student"][j] += d * d
    }
    let (rotation, _, _) = try! full.measurements()
    let (last_error, full_velocity) = full.memory()
    for name, window in windows {
      for j in 0..<nu {
        let d = alternatives[name][j] - teacher[j]
        errors[name][j] += d * d
      }
      let delta = Array::makei(3, fn(j) {
        window.velocity()[j] - full_velocity[j]
      })
      let local = @balance.matvec(@balance.transpose(rotation), delta)
      velocity_error[name] += local[0] * local[0] + local[1] * local[1]
    }
    let indices = groups["ankle_waist"]
    last_measurement = {
      "step": count.to_json(),
      "time_s": (count.to_double() * dt).to_json(),
      "root_height_m": runtime.root_height().to_json(),
      "upright_z": rotation[8].to_json(),
      "local_com_error_m": @balance.matvec(
        @balance.transpose(rotation),
        last_error.unwrap(),
      ).to_json(),
      "local_filtered_velocity_m_s": @balance.matvec(
        @balance.transpose(rotation),
        full_velocity,
      ).to_json(),
      "h10_local_filtered_velocity_m_s": @balance.matvec(
        @balance.transpose(rotation),
        windows["10"].velocity(),
      ).to_json(),
      "student_ankle_waist": indices.map(fn(i) { student[i] }).to_json(),
      "teacher_ankle_waist": indices.map(fn(i) { teacher[i] }).to_json(),
      "h10_teacher_ankle_waist": indices
      .map(fn(i) { alternatives["10"][i] })
      .to_json(),
    }
    if count % 5 == 0 {
      measurements.push(last_measurement)
    }
    count += 1
    match mode {
      "student" => student
      "teacher" => teacher
      "ankle" | "ankle_waist" | "lower" =>
        @balance.blend_actions(student, teacher, groups[mode])
      "teacher_no_memory" => alternatives["1"]
      "teacher_h10" => alternatives["10"]
      "teacher_h50" => alternatives["50"]
      _ => abort("unknown balance intervention mode")
    }
  }
  let rng = @numeric.Rng::new(reset_seed.to_uint())
  let (episode, trial) = runtime.rollout(
    case,
    reset_seed,
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
  if (count - 1) % 5 != 0 {
    measurements.push(last_measurement)
  }
  let shadow : Map[String, Json] = {}
  for name, squared in errors {
    let group_errors : Map[String, Double] = {}
    for group, indices in groups {
      let mut sum = 0.0
      for i in indices {
        sum += squared[i]
      }
      group_errors[group] = (sum / (indices.length() * count).to_double()).sqrt()
    }
    let fields : Map[String, Json] = {
      "per_joint_rmse_rad": squared
      .map(fn(x) { (x / count.to_double()).sqrt() })
      .to_json(),
      "group_rmse_rad": group_errors.to_json(),
    }
    if name != "student" {
      fields["local_velocity_rmse_m_s"] = (velocity_error[name] /
        (2 * count).to_double())
        .sqrt()
        .to_json()
    }
    shadow[name] = Json::object(fields)
  }
  (
    episode,
    trial,
    {
      "samples": count.to_json(),
      "shadow": shadow.to_json(),
      "measurements": measurements.to_json(),
    },
  )
}

///|
/// Frozen parent/teacher shadow interventions with independently repeated direct baselines, canonical and train-family scopes, and unchanged parameter guards.
pub async fn run(
  library : String,
  scene : String,
  config_path : String,
  collection_path : String,
  experiment_path : String,
  teacher_path : String,
  policies : String,
  provider_source : String,
  output : String,
) -> Json {
  let config = @artifacts.load_json(config_path)
  let collection = @artifacts.load_json(collection_path)
  let experiment = @artifacts.load_json(experiment_path)
  let teacher = @artifacts.load_json(teacher_path)
  let source_report = @artifacts.load_json(policies + "/report.json")
  let provider_sha = @artifacts.sha256(@fs.read_file(provider_source).binary())
  guard field(teacher, "provider_sha256") == provider_sha.to_json() else {
    fail("intervention teacher source changed")
  }
  let parameters = @balance_native.parameters_from_json(
    field(teacher, "parameters"),
  )
  let seeds : Array[Int32] = @json.from_json(field(config, "seeds"))
  let modes : Array[String] = @json.from_json(field(config, "modes"))
  let canonical_seeds : Array[Int32] = @json.from_json(
    field(config, "canonical_reset_seeds"),
  )
  let train_cases : Array[Json] = @json.from_json(field(collection, "cases"))
  let canonical : Array[Json] = @json.from_json(field(experiment, "cases"))
  let source_runs : Array[Json] = @json.from_json(field(source_report, "runs"))
  let dt = number(collection, "control_dt_s")
  let duration = number(config, "duration_s")
  let runtime = @native_physics.Runtime::open(library, scene)
  let groups = @balance.joint_groups(runtime.joint_names())
  guard groups["ankle"].length() == 4 &&
    groups["ankle_waist"].length() == 5 &&
    groups["lower"].length() == 12 &&
    groups["all"].length() == 29 else {
    fail("expected declared G1 intervention channels")
  }
  if !@fs.exists(output) {
    @fs.mkdir(output, recursive=true)
  }
  let report_sources = @report_contract.capture(output, [
    (
      "teacher_implementation_sha256", "src/learning_balance/physics/teacher.mbt",
    ),
    ("teacher_algorithm_sha256", "src/learning_balance/teacher.mbt"),
    ("provider_sha256", "src/learning_balance/intervention/intervention.mbt"),
    ("teacher_provider_sha256", provider_source),
  ])
  let rows : Array[Json] = []
  let logs : Array[Json] = []
  for seed in seeds {
    let native_path = policies +
      "/actor-seed-" +
      seed.to_string() +
      ".moon.json"
    let path = if @fs.exists(native_path) {
      native_path
    } else {
      policies + "/actor-seed-" + seed.to_string() + ".pt"
    }
    let actor = @temporal.load_temporal(path)
    let matching = source_runs.filter(fn(row) {
      match row {
        Object(fields) => fields.get("seed") == Some(seed.to_json())
        _ => false
      }
    })
    guard matching.length() == 1 else {
      fail("intervention parent seed not unique in source report")
    }
    let selected = if path.has_suffix(".pt") {
      @artifacts.load_torch_checkpoint(path)
      .field("selected_update")
      .plain_json()
    } else {
      field(
        @artifacts.load_checkpoint(path, "temporal-actor").metadata,
        "selected_update",
      )
    }
    guard selected == field(matching[0], "selected_update") else {
      fail("intervention parent selection differs")
    }
    let initial = actor.parameters()
    let direct : Map[(String, Int32, String), Json] = {}
    for raw_case in canonical {
      let case : @native_physics.Case = @json.from_json(raw_case)
      for reset in canonical_seeds {
        let (offset, schedule) = @balance_native.sample_reference(
          runtime, raw_case, reset,
        )
        let (student, _) = @temporal_native.rollout(
          runtime,
          actor,
          case,
          reset,
          duration,
          dt,
          @numeric.Rng::new(reset.to_uint()),
          offset?,
          schedule?,
          fall_height=number(config, "fall_height_m"),
          fall_upright=number(config, "fall_upright_z"),
        )
        let oracle = @balance_native.NativeBalanceTeacher::new(
          runtime, parameters, dt,
        )
        let rng = @numeric.Rng::new(reset.to_uint())
        let (reference, _) = runtime.rollout(
          case,
          reset,
          "policy",
          duration,
          dt,
          fn() { rng.normal() },
          fall_height=number(config, "fall_height_m"),
          fall_upright=number(config, "fall_upright_z"),
          policy=fn(obs, goal) { try! oracle.predict(obs, goal) },
          offset?,
          schedule?,
        )
        direct[(case.id, reset, "student")] = student.steps.to_json()
        direct[(case.id, reset, "teacher")] = reference.steps.to_json()
      }
    }
    for mode in modes {
      let episodes : Array[@native_physics.Episode] = []
      let trials : Array[Json] = []
      let diagnostics : Array[Json] = []
      let scope_groups = [
        (
          "train",
          train_cases,
          [number(config, "train_reset_seed_base").to_int() + 10000 * seed],
        ),
        ("canonical-development", canonical, canonical_seeds),
      ]
      let summaries : Map[String, Json] = {}
      for (scope, cases, resets) in scope_groups {
        let scoped_trials : Array[Json] = []
        for raw_case in cases {
          for reset in resets {
            let (episode, trial, diagnostic) = probe_trial(
              runtime, actor, raw_case, reset, mode, config, parameters, dt,
            )
            if scope == "canonical-development" &&
              (mode == "student" || mode == "teacher") {
              guard direct[(episode.case_id, reset, mode)] ==
                episode.steps.to_json() else {
                fail("shadow queries changed direct canonical physics")
              }
            }
            let ident = episode.id +
              "-policy-" +
              seed.to_string() +
              "-" +
              mode +
              "-" +
              scope
            let episode : @native_physics.Episode = { ..episode, id: ident, }
            let trial_fields : Map[String, Json] = match trial.to_json() {
              Object(fields) => fields.copy()
              _ => abort("trial is not an object")
            }
            trial_fields["episode_id"] = ident.to_json()
            trial_fields["scope"] = scope.to_json()
            trial_fields["mode"] = mode.to_json()
            let trial = Json::object(trial_fields)
            episodes.push(episode)
            trials.push(trial)
            scoped_trials.push(trial)
            diagnostics.push(diagnostic)
          }
        }
        summaries[scope] = @balance.summarize_recorded_trials(scoped_trials)
      }
      logs.push({
        "seed": seed.to_json(),
        "mode": mode.to_json(),
        "dataset": runtime.dataset(
          episodes,
          "moonbit-balance-intervention",
          dt~,
        ),
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
      rows.push({
        "seed": seed.to_json(),
        "mode": mode.to_json(),
        "summaries": summaries.to_json(),
        "transitions": transitions.to_json(),
        "episodes": episodes.length().to_json(),
        "diagnostics": diagnostics.to_json(),
        "trials": trials.to_json(),
        "actor_sha256": @artifacts.sha256(@fs.read_file(path).binary()).to_json(),
        "direct_baselines_match": true,
      })
    }
    guard actor.parameters() == initial else {
      fail("intervention mutated incoming actor parameters")
    }
  }
  let named_groups : Map[String, Array[String]] = {}
  let names = runtime.joint_names()
  for name, indices in groups {
    named_groups[name] = indices.map(fn(i) { names[i] })
  }
  let report : Json = {
    "format": "moonrobo.g1-balance-intervention.v1",
    "config": config,
    "rows": rows.to_json(),
    "joint_names": names.to_json(),
    "groups": named_groups.to_json(),
    "source_policy_report_sha256": @artifacts.sha256(
      @fs.read_file(policies + "/report.json").binary(),
    ).to_json(),
    "teacher_sha256": @artifacts.sha256(@fs.read_file(teacher_path).binary()).to_json(),
    "teacher_provider_sha256": provider_sha.to_json(),
    "physics_log_sha256": @artifacts.sha256(
      @fs.read_file(output + "/intervention-physics.jsonl.gz").binary(),
    ).to_json(),
    "actor_and_normalization_unchanged": true,
    "verification_rollouts": (seeds.length() *
    canonical.length() *
    canonical_seeds.length() *
    2).to_json(),
    "scope": "Frozen-policy shadow interventions; canonical development and training-family audits only",
    "learned_policy_qualified": false,
    "physical_execution_allowed": false,
    "source_language": "moonbit",
  }
  let report = @report_contract.attach(report, report_sources)
  ignore(@artifacts.save_json(output + "/report.json", report))
  report
}
