///|
pub fn control(
  runtime : @native_physics.Runtime,
  geometry : @balance.Kinematics,
  parameters : @balance.FeedbackParameters,
  config : Json,
  experiment : Json,
  actors : Array[(Int32, @temporal.TemporalPolicy, String)],
  dt : Double,
) -> (Array[Json], Array[Json]) raise {
  let modes : Array[String] = @json.from_json(field(config, "control_modes"))
  let cases : Array[Json] = @json.from_json(field(experiment, "cases"))
  let seeds : Array[Int32] = @json.from_json(
    field(config, "control_reset_seeds"),
  )
  let (lower, upper) = runtime.control_bounds()
  let indices = @balance.joint_groups(runtime.joint_names())["ankle"]
  let rows : Array[Json] = []
  let logs : Array[Json] = []
  for (parent_seed, actor, digest) in actors {
    let initial = actor.parameters()
    for mode in modes {
      let episodes : Array[@native_physics.Episode] = []
      let trials : Array[@native_physics.Trial] = []
      let mut maximum_offline_error = 0.0
      for raw_case in cases {
        let case : @native_physics.Case = @json.from_json(raw_case)
        for reset in seeds {
          let (offset, schedule) = @balance_native.sample_reference(
            runtime, raw_case, reset,
          )
          let mut nominal : Array[Double] = []
          let parent = @temporal.TemporalRunner::new(
            actor.temporal,
            dt,
            fn(time) {
              try! runtime.reference(
                nominal,
                case.motion,
                time,
                offset?,
                schedule?,
              )
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
          let history = @float32.History::new(geometry, dt, Some(10))
          let oracle = @intervention.WindowTeacher::new(
            runtime, parameters, 10, dt,
          )
          let online : Array[Array[Double]] = []
          let predict = fn(
            obs : Array[Double],
            goal : Array[Double],
          ) -> Array[Double] {
            if nominal.is_empty() {
              nominal = Array::makei(goal.length(), fn(i) { obs[i] })
            }
            let student = parent.predict(obs, goal)
            let feature = history.observe(obs)
            online.push(feature)
            let derived = @float32.observation_ankle_feedback(
              parameters,
              geometry.nu,
              indices,
              lower,
              upper,
              obs,
              goal,
              feature,
            )
            if mode == "student" {
              student
            } else if mode == "oracle_h10_ankle" {
              @balance.blend_actions(
                student,
                try! oracle.predict(obs, goal),
                indices,
              )
            } else {
              for j in 0..<indices.length() {
                student[indices[j]] = derived[j]
              }
              student
            }
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
          let offline = @float32.sequence_features(
            geometry,
            episode.steps.map(fn(s) { s.observation }),
            dt,
            Some(10),
            GravityGyro,
          )
          let check = errors(online, offline)
          let error = number(check, "maximum_error")
          maximum_offline_error = @balance.clip(
            error,
            maximum_offline_error,
            1.0 / 0.0,
          )
          guard error < 2.0e-5 else {
            fail("online/offline observation features disagree")
          }
          let ident = episode.id +
            "-features-policy-" +
            parent_seed.to_string() +
            "-" +
            mode
          episodes.push({ ..episode, id: ident, })
          trials.push({ ..trial, episode_id: ident, })
        }
      }
      let trials_json = trials.map(fn(t) { t.to_json() })
      let mut transitions = 0
      for episode in episodes {
        transitions += episode.steps.length()
      }
      logs.push({
        "seed": parent_seed.to_json(),
        "mode": mode.to_json(),
        "dataset": runtime.dataset(episodes, "moonbit-feature-feedback", dt~),
        "trials": trials_json.to_json(),
      })
      rows.push({
        "seed": parent_seed.to_json(),
        "mode": mode.to_json(),
        "summary": @balance.summarize_recorded_trials(trials_json),
        "maximum_online_offline_feature_error": maximum_offline_error.to_json(),
        "episodes": episodes.length().to_json(),
        "transitions": transitions.to_json(),
        "trials": trials_json.to_json(),
        "actor_sha256": digest.to_json(),
      })
    }
    guard actor.parameters() == initial else {
      fail("feature feedback study mutated learned actor")
    }
  }
  (rows, logs)
}

///|
/// Verification and fixed-feedback control retain actual physics, native geometry truth, source archive hashes and offline/online consistency checks. Float32 arithmetic rounds independently at every operator; runtime comparisons remain deferred.
pub async fn run(
  library : String,
  scene : String,
  config_path : String,
  teacher_path : String,
  intervention : String,
  experiment_path : String,
  policies : String,
  provider_source : String,
  output : String,
  feature_source~ : String = "src/learning_balance/geometry.mbt",
  study_source~ : String = "src/learning_balance/feature_study/control.mbt",
) -> Json {
  let config = @artifacts.load_json(config_path)
  let teacher = @artifacts.load_json(teacher_path)
  let experiment = @artifacts.load_json(experiment_path)
  guard @artifacts.sha256(@fs.read_file(provider_source).binary()).to_json() ==
    field(teacher, "provider_sha256") else {
    fail("feature teacher implementation changed")
  }
  let parameters = @balance_native.parameters_from_json(
    field(teacher, "parameters"),
  )
  let runtime = @native_physics.Runtime::open(library, scene)
  let geometry = @balance_native.make_spec(runtime)
  if !@fs.exists(output) {
    @fs.mkdir(output, recursive=true)
  }
  let report_sources = @report_contract.capture(output, [
    (
      "teacher_implementation_sha256", "src/learning_balance/physics/teacher.mbt",
    ),
    ("teacher_algorithm_sha256", "src/learning_balance/teacher.mbt"),
    ("provider_sha256", study_source),
    ("feature_provider_sha256", feature_source),
    ("teacher_provider_sha256", provider_source),
  ])
  guard geometry.to_json() is Object(geometry_fields) else {
    fail("kinematics object required")
  }
  geometry_fields["format"] = "moonrobo.balance-kinematics.v1"
  geometry_fields["joint_names"] = runtime.joint_names().to_json()
  let kinematics_sha = @artifacts.save_json(
    output + "/kinematics.json",
    Json::object(geometry_fields),
  )
  let source_report = @artifacts.load_json(intervention + "/report.json")
  let source_path = intervention + "/intervention-physics.jsonl.gz"
  let source_sha : String = @json.from_json(
    field(source_report, "physics_log_sha256"),
  )
  let records = @artifacts.load_jsonl(source_path, expected_sha256=source_sha)
  let poses = random_geometry(
    runtime,
    geometry,
    number(config, "random_pose_count").to_int(),
    number(config, "random_pose_seed").to_uint(),
  )
  let dt = number(experiment, "control_dt_s")
  let verified = verify_log(runtime, geometry, parameters, config, records, dt)
  let verification_sha = @artifacts.save_json(
    output + "/feature-verification.json",
    {
      "rows": verified.to_json(),
      "scope": "Privileged state provides verification truth only; observation-derived modules use static model constants and current/past observations",
      "dtypes": ["float64", "float32"],
      "float32_parity_verified": false,
    },
  )
  let seeds : Array[Int32] = @json.from_json(field(config, "seeds"))
  let actors : Array[(Int32, @temporal.TemporalPolicy, String)] = []
  for seed in seeds {
    let native = policies + "/actor-seed-" + seed.to_string() + ".moon.json"
    let path = if @fs.exists(native) {
      native
    } else {
      policies + "/actor-seed-" + seed.to_string() + ".pt"
    }
    actors.push(
      (
        seed,
        @temporal.load_temporal(path),
        @artifacts.sha256(@fs.read_file(path).binary()),
      ),
    )
  }
  let (rows, logs) = control(
    runtime, geometry, parameters, config, experiment, actors, dt,
  )
  let log_sha = @artifacts.save_jsonl(
    output + "/feature-feedback-physics.jsonl.gz",
    logs,
  )
  let mut points = 0
  for row in verified {
    points += number(row, "points").to_int()
  }
  let report : Json = {
    "format": "moonrobo.g1-observation-balance-features.v1",
    "config": config,
    "kinematics_sha256": kinematics_sha.to_json(),
    "input_log_sha256": source_sha.to_json(),
    "random_pose_geometry": poses,
    "verified_episodes": verified.length().to_json(),
    "verified_points": points.to_json(),
    "verification_sha256": verification_sha.to_json(),
    "control": rows.to_json(),
    "control_log_sha256": log_sha.to_json(),
    "provider_sha256": @artifacts.sha256(@fs.read_file(study_source).binary()).to_json(),
    "feature_provider_sha256": @artifacts.sha256(
      @fs.read_file(feature_source).binary(),
    ).to_json(),
    "scope": "Privileged state is verification truth only; control features use static model constants and current/past observations",
    "learned_policy_qualified": false,
    "physical_execution_allowed": false,
    "float32_parity_verified": false,
    "source_language": "moonbit",
  }
  let report = @report_contract.attach(report, report_sources)
  ignore(@artifacts.save_json(output + "/report.json", report))
  report
}
