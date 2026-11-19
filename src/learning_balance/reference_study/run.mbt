///|
pub async fn run(
  library : String,
  scene : String,
  config_path : String,
  collection_path : String,
  teacher_study : String,
  output : String,
  teacher_provider_source~ : String,
  teacher_kernel_source~ : String,
  provider_source~ : String,
  reference_provider_source~ : String,
) -> Json {
  let config = @artifacts.load_json(config_path)
  let collection = @artifacts.load_json(collection_path)
  let teacher_path = teacher_study + "/teacher.json"
  let teacher = @artifacts.load_json(teacher_path)
  let teacher_provider_sha = @artifacts.sha256(
    @fs.read_file(teacher_provider_source).binary(),
  )
  guard teacher_provider_sha == text(teacher, "provider_sha256") else {
    fail(
      "reference source native teacher implementation changed; Python teacher hashes are not native hashes",
    )
  }
  let teacher_kernel_sha = @artifacts.sha256(
    @fs.read_file(teacher_kernel_source).binary(),
  )
  let teacher_sha = @artifacts.sha256(@fs.read_file(teacher_path).binary())
  let parameters : @balance.FeedbackParameters = @json.from_json(
    field(teacher, "parameters"),
  )
  let runtime = @sim.Runtime::open(library, scene)
  let dt = number(collection, "control_dt_s")
  ignore(runtime.control_substeps(dt))
  let layout = layout(runtime, dt)
  let revision = text(collection, "source_revision")
  let cases : Array[@sim.Case] = @json.from_json(field(collection, "cases"))
  let modes : Array[String] = @json.from_json(field(config, "modes"))
  let origins : Array[Double] = @json.from_json(
    field(config, "replay_origins_s"),
  )
  let reset_seed : Int32 = @json.from_json(field(config, "source_reset_seed"))
  guard !cases.is_empty() && !modes.is_empty() && !origins.is_empty() else {
    fail("reference study needs cases, replay modes and origins")
  }
  guard modes.all(mode => mode == "source-setpoint" || mode == "joint-position") else {
    fail(
      "reference study modes require source-setpoint or joint-position; policy needs a separate explicit actor",
    )
  }
  let seen : Array[String] = []
  for case in cases {
    guard case.split == "train" &&
      !case.id.contains("/") &&
      case.id != "." &&
      case.id != ".." &&
      !seen.contains(case.id) else {
      fail(
        "new reference development accepts distinct training-family clip IDs only",
      )
    }
    seen.push(case.id)
  }
  @fs.mkdir(output + "/clips", recursive=true)
  let start_time = @async.now()
  let clips : Array[Json] = []
  let collection_trials : Array[Json] = []
  let replay_trials : Array[Json] = []
  let sources : Array[Json] = []
  let replays : Array[Json] = []
  let mut collection_seconds = 0.0
  let mut replay_seconds = 0.0
  for case in cases {
    let frames : Array[@balance_native.ReferenceFrame] = []
    let velocities : Array[Array[Array[Double]]] = []
    let teacher_policy = @balance_native.NativeBalanceTeacher::new(
      runtime, parameters, dt,
    )
    let rng = @numeric.Rng::new(reset_seed.reinterpret_as_uint())
    let started = @async.now()
    let (episode, raw_trial) = runtime.rollout(
      case,
      reset_seed,
      "policy",
      number(config, "duration_s"),
      dt,
      () => rng.normal(),
      fall_height=number(config, "fall_height_m"),
      fall_upright=number(config, "fall_upright_z"),
      policy=(obs, goal) => try! teacher_policy.predict(obs, goal),
      trace=(i, _action, _goal) => {
        frames.push(
          try! @balance_native.capture_frame(runtime, i.to_double() * dt),
        )
        velocities.push(
          Array::makei(runtime.body_count() - 1, b => {
            try! runtime.body_object_velocity_world(b + 1)
          }),
        )
      },
    )
    frames.push(
      @balance_native.capture_frame(
        runtime,
        episode.steps.length().to_double() * dt,
      ),
    )
    let final_velocities : Array[Array[Double]] = []
    for body in 1..<runtime.body_count() {
      final_velocities.push(runtime.body_object_velocity_world(body))
    }
    velocities.push(final_velocities)
    collection_seconds += (@async.now() - started).to_double() / 1000.0
    guard raw_trial.to_json() is Object(trial_fields) else {
      fail("invalid recorded trial")
    }
    let trimmed : Map[String, Json] = Map([])
    for key, value in trial_fields {
      if key != "replay" {
        trimmed[key] = value
      }
    }
    let trial = Json::object(trimmed)
    collection_trials.push(trial)
    sources.push({
      "dataset": runtime.dataset([episode], revision, dt~),
      "trial": trial,
    })
    // Persist failed source evidence before rejecting it as a successful reference.
    ignore(@artifacts.save_jsonl(output + "/source-physics.jsonl.gz", sources))
    guard !raw_trial.failed else {
      fail(
        "a failed source is retained but cannot become a successful reference",
      )
    }
    let clip_file = output + "/clips/" + case.id + ".npz"
    let clip_sha = @artifacts.save_npz(
      clip_file,
      archive_frames(frames, velocities, episode),
    )
    // Replay always reconstructs from serialized and hash-verified NPZ bytes.
    let archive = @artifacts.load_npz(clip_file, expected_sha256=clip_sha)
    let reference = reference_from_arrays(runtime, archive, dt)
    let clip : Json = {
      "id": case.id.to_json(),
      "source_family": case.family.to_json(),
      "split": case.split.to_json(),
      "case": case.to_json(),
      "source_reset_seed": reset_seed.to_json(),
      "source_episode_id": episode.id.to_json(),
      "file": ("clips/" + case.id + ".npz").to_json(),
      "sha256": clip_sha.to_json(),
      "frames": reference.frames.length().to_json(),
      "steps": reference.controls.length().to_json(),
      "duration_s": (reference.controls.length().to_double() * dt).to_json(),
      "source_teacher_sha256": teacher_sha.to_json(),
      "source_trial": trial,
    }
    clips.push(clip)
    for origin_s in origins {
      let origin = @math.round(origin_s / dt).to_int()
      guard (origin.to_double() * dt - origin_s).abs() <=
        1.0e-8 + 1.0e-5 * origin_s.abs() else {
        fail("replay origin is not a control boundary")
      }
      for mode in modes {
        let started = @async.now()
        let (replay, result) = @balance_native.replay_reference(
          runtime,
          reference,
          case,
          origin,
          mode,
          fall_height=number(config, "fall_height_m"),
          fall_upright=number(config, "fall_upright_z"),
        )
        replay_seconds += (@async.now() - started).to_double() / 1000.0
        let dataset = mutate(runtime.dataset([replay], revision, dt~), {
          "dataset_id": ("g1-full-body-reference-" + case.id).to_json(),
          "goal_axes": field(layout, "goal_axes"),
          "provenance": "Fresh successful procedural teacher physics; full-body reference targets; source controls excluded from goal",
        })
        replays.push({
          "reference_id": case.id.to_json(),
          "reference_sha256": clip_sha.to_json(),
          "dataset": dataset,
          "trial": result,
        })
        replay_trials.push(result)
        println(
          mutate(result, { "reference_id": case.id.to_json() }).stringify(),
        )
      }
    }
    ignore(@artifacts.save_jsonl(output + "/replay-physics.jsonl.gz", replays))
  }
  let source_sha = @artifacts.sha256(
    @fs.read_file(output + "/source-physics.jsonl.gz").binary(),
  )
  let scene_sha = @artifacts.sha256(@fs.read_file(scene).binary())
  let manifest : Json = {
    "format": "moonrobo.g1-full-body-reference.v1",
    "evidence_class": "physics-simulation",
    "model_ref": field(runtime.dataset([], revision, dt~), "model_ref"),
    "scene_sha256": scene_sha.to_json(),
    "mujoco_version": runtime.version().to_json(),
    "layout": layout,
    "provenance": "New training-family procedural teacher trajectories; no mocap, canonical/audit data, demo material or hardware",
    "source_physics_sha256": source_sha.to_json(),
    "clips": clips.to_json(),
    "physical_execution_allowed": false,
  }
  let manifest_sha = @artifacts.save_json(output + "/manifest.json", manifest)
  let summaries : Array[Json] = []
  for mode in modes {
    let trials : Array[Json] = []
    for trial in replay_trials {
      if text(trial, "controller") == mode {
        trials.push(trial)
      }
    }
    guard !trials.is_empty() else { fail("replay mode has no recorded trials") }
    let mut count = 0.0
    let mut falls = 0
    let mut simulated = 0.0
    let mut requested = 0.0
    let mut max_error = 0.0
    for trial in trials {
      count += number(trial, "steps")
      simulated += number(trial, "simulated_seconds")
      requested += number(trial, "requested_seconds")
      max_error = max_error.max(number(trial, "max_state_component_error"))
      if field(trial, "failed") == true.to_json() {
        falls += 1
      }
    }
    guard count > 0.0 else { fail("replay mode has no physical steps") }
    let summary : Map[String, Json] = {
      "controller": mode.to_json(),
      "trials": trials.length().to_json(),
      "falls": falls.to_json(),
      "steps": count.to_int().to_json(),
      "simulated_seconds": simulated.to_json(),
      "requested_seconds": requested.to_json(),
      "max_state_component_error": max_error.to_json(),
    }
    for
      metric in [
        "joint_rmse_rad", "body_position_rmse_m", "root_position_rmse_m", "root_orientation_rmse_rad",
        "joint_speed_rmse_rad_per_s", "root_linear_speed_rmse_m_per_s", "root_angular_speed_rmse_rad_per_s",
      ] {
      let mut weighted = 0.0
      for trial in trials {
        let value = number(trial, metric)
        weighted += value * value * number(trial, "steps")
      }
      summary[metric] = (weighted / count).sqrt().to_json()
    }
    summaries.push(Json::object(summary))
  }
  let report : Json = {
    "format": "moonrobo.g1-full-body-reference-study.v1",
    "source_language": "moonbit",
    "numeric_backend": "native-cpu-f64",
    "config": config,
    "manifest_sha256": manifest_sha.to_json(),
    "replay_sha256": @artifacts.sha256(
      @fs.read_file(output + "/replay-physics.jsonl.gz").binary(),
    ).to_json(),
    "provider_sha256": @artifacts.sha256(
      @fs.read_file(provider_source).binary(),
    ).to_json(),
    "reference_provider_sha256": @artifacts.sha256(
      @fs.read_file(reference_provider_source).binary(),
    ).to_json(),
    "teacher_sha256": teacher_sha.to_json(),
    "teacher_provider_sha256": teacher_provider_sha.to_json(),
    "teacher_kernel_sha256": teacher_kernel_sha.to_json(),
    "collection_trials": collection_trials.to_json(),
    "replay_trials": replay_trials.to_json(),
    "summaries": summaries.to_json(),
    "collection_seconds": collection_seconds.to_json(),
    "replay_seconds": replay_seconds.to_json(),
    "provider_seconds": ((@async.now() - start_time).to_double() / 1000.0).to_json(),
    "training_updates": 0,
    "release_qualified": false,
    "physical_execution_allowed": false,
    "scope": "Source-setpoint replay is a feasibility oracle, not a deployable or learned tracker. Joint-position baseline is not the sustained v2 actor. No learning-efficiency or motion generalization result.",
    "parity_status": "awaiting-python-comparison",
  }
  ignore(@artifacts.save_json(output + "/report.json", report))
  report
}
