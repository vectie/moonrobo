///|
/// Complete train-only physical counterfactual collection from restored integration states.
pub async fn run_counterfactual(
  library : String,
  scene : String,
  config_path : String,
  experiment_path : String,
  policies_directory : String,
  output : String,
) -> Unit {
  let config = @artifacts.load_json(config_path)
  let experiment = @artifacts.load_json(experiment_path)
  let runtime = @native_physics.Runtime::open(library, scene)
  let policy_seeds : Array[Int32] = @json.from_json(
    field(config, "policy_seeds"),
  )
  let reset_seeds : Array[Int32] = @json.from_json(field(config, "reset_seeds"))
  let snapshots : Array[Int32] = @json.from_json(
    field(config, "snapshot_steps"),
  )
  guard policy_seeds.length() == reset_seeds.length() else {
    fail("counterfactual policy/reset seed lengths differ")
  }
  let cases : Array[Json] = @json.from_json(field(experiment, "cases"))
  let branch_config : BranchConfig = {
    branch_steps: integer(config, "branch_steps"),
    pulse_steps: integer(config, "pulse_steps"),
    dt: number(experiment, "control_dt_s"),
    fall_height: number(config, "fall_height_m"),
    fall_upright: number(config, "fall_upright_z"),
  }
  let episodes : Array[@native_physics.Episode] = []
  let episode_json : Array[Json] = []
  let trials : Array[Json] = []
  let parents : Array[Json] = []
  let omitted : Array[Json] = []
  let checkpoint_digests : Map[String, Json] = Map([])
  let mut restore_error = 0.0
  let mut falls = 0
  let mut transitions = 0
  let mut late_transitions = 0
  for index in 0..<policy_seeds.length() {
    let policy_seed = policy_seeds[index]
    let reset_seed = reset_seeds[index]
    let checkpoint_path = actor_path(policies_directory, policy_seed)
    let checkpoint_bytes = @fs.read_file(checkpoint_path).binary()
    let digest = @artifacts.sha256(checkpoint_bytes)
    let actor = @training.actor_from_checkpoint(
      @training.load_learning_checkpoint(
        checkpoint_path,
        "g1-actor",
        expected_sha256=digest,
      ),
    )
    checkpoint_digests[checkpoint_path] = digest.to_json()
    let predict = (obs, goal) => actor.predict(obs, goal)
    for case_json in cases {
      if text(case_json, "split") != "train" {
        continue
      }
      let case : @native_physics.Case = @json.from_json(case_json)
      guard ["stand", "pose_offset"].contains(case.motion) else {
        fail("counterfactual branch goals must be constant")
      }
      let rng = @numeric.Rng::new(reset_seed.to_uint())
      let origins : Map[Int32, BranchOrigin] = Map([])
      let controls : Array[Array[Double]] = []
      let trace = fn(
        step : Int32,
        action : Array[Double],
        goal : Array[Double],
      ) -> Unit {
        if snapshots.contains(step) {
          let previous = if step == 0 {
            try! runtime.clip_control(
              runtime.q_indices().map(i => runtime.state()[i]),
            )
          } else {
            controls[step - 1]
          }
          origins[step] = {
            integration: runtime.integration(),
            previous,
            goal,
            start_step: step,
            parent_episode_id: "pending",
          }
        }
        controls.push(action.copy())
      }
      let offset = if case.motion == "pose_offset" {
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
      } else {
        None
      }
      let (parent, parent_trial) = runtime.rollout(
        case,
        reset_seed,
        "policy",
        number(experiment, "duration_s"),
        branch_config.dt,
        () => rng.normal(),
        fall_height=branch_config.fall_height,
        fall_upright=branch_config.fall_upright,
        policy=predict,
        offset?,
        trace~,
      )
      let parent_id = parent.id + "-" + digest
      let saved_origins : Array[Json] = []
      for start in snapshots {
        guard origins.get(start) is Some(raw_origin) else {
          omitted.push({
            "parent_episode_id": parent_id.to_json(),
            "start_step": start.to_json(),
            "reason": "parent-already-ended",
          })
          continue
        }
        let origin : BranchOrigin = {
          ..raw_origin,
          parent_episode_id: parent_id,
        }
        saved_origins.push({
          "integration": origin.integration.to_json(),
          "start_step": origin.start_step.to_json(),
          "previous": origin.previous.to_json(),
          "goal": origin.goal.to_json(),
          "parent_episode_id": parent_id.to_json(),
        })
        let pulse_rng = @numeric.Rng::new(
          reset_seed.to_uint() ^
          (policy_seed.to_uint() * 0x9E3779B9U) ^
          (start.to_uint() * 0x85EBCA6BU) ^
          1931U,
        )
        let bound = number(config, "pulse_clip_rad")
        let std = number(config, "pulse_std_rad")
        guard bound >= 0 && std >= 0 else { fail("negative pulse scale") }
        let delta = Array::makei(origin.goal.length(), _ => {
          let v = std * pulse_rng.normal()
          if v < -bound {
            -bound
          } else if v > bound {
            bound
          } else {
            v
          }
        })
        for sign in [0, 1, -1] {
          let episode_id = parent_id +
            "-step-" +
            start.to_string() +
            "-branch-" +
            sign.to_string()
          let pulse = delta.map(v => sign.to_double() * v)
          let (episode, trial) = branch_rollout(
            runtime, origin, case, predict, pulse, branch_config, episode_id,
          )
          if sign == 0 {
            restore_error = @math.maximum(
              restore_error,
              unperturbed_replay_error(parent, start, episode),
            )
          }
          if trial.failed {
            falls += 1
          }
          transitions += episode.steps.length()
          for step in episode.steps {
            if step.time_s >= 2 {
              late_transitions += 1
            }
          }
          let row = episode.to_json()
          match row {
            Object(fields) => {
              fields["parent_episode_id"] = parent_id.to_json()
              fields["parent_step"] = start.to_json()
              fields["perturbation_rad"] = pulse.to_json()
              fields["pulse_steps"] = branch_config.pulse_steps.to_json()
            }
            _ => ()
          }
          episodes.push(episode)
          episode_json.push(row)
          trials.push({
            "episode_id": episode.id.to_json(),
            "case_id": case.id.to_json(),
            "parent_step": start.to_json(),
            "steps": episode.steps.length().to_json(),
            "failed": trial.failed.to_json(),
            "end_reason": trial.end_reason.to_json(),
            "branch_seconds": trial.simulated_seconds.to_json(),
            "parent_elapsed_seconds": (start.to_double() * branch_config.dt).to_json(),
            "joint_rmse_rad": trial.joint_rmse_rad.to_json(),
            "pulse_sign": sign.to_json(),
            "replay": trial.replay.to_json(),
          })
        }
      }
      parents.push({
        "episode_id": parent_id.to_json(),
        "case_id": case.id.to_json(),
        "policy_seed": policy_seed.to_json(),
        "reset_seed": reset_seed.to_json(),
        "steps": parent.steps.length().to_json(),
        "end_reason": parent_trial.end_reason.to_json(),
        "origins": saved_origins.to_json(),
      })
    }
  }
  let dataset = runtime.dataset(
    episodes,
    text(experiment, "source_revision"),
    dt=branch_config.dt,
    episode_json~,
  )
  match dataset {
    Object(fields) => {
      fields["dataset_id"] = "g1-counterfactual-physical-branches".to_json()
      fields["provenance"] = "MuJoCo restored training-only pre-fall integration states; antithetic finite action pulses; source-family ownership retained".to_json()
    }
    _ => ()
  }
  let summary : Json = {
    "episodes": episodes.length().to_json(),
    "transitions": transitions.to_json(),
    "falls": falls.to_json(),
    "branch_time_limits": (episodes.length() - falls).to_json(),
    "after_two_second_transitions": late_transitions.to_json(),
    "maximum_unperturbed_replay_error": restore_error.to_json(),
    "omitted_origins": omitted.length().to_json(),
  }
  let report : Json = {
    "format": "moonrobo.moonbit-counterfactual-collection.v1",
    "config": config,
    "experiment": experiment,
    "checkpoint_sha256": checkpoint_digests.to_json(),
    "summary": summary,
    "parents": parents.to_json(),
    "omitted": omitted.to_json(),
    "trials": trials.to_json(),
    "physical_execution_allowed": false,
    "scope": "training-only finite branches, not qualification trials",
    "parity_status": "awaiting-python-comparison",
  }
  if !@fs.exists(output) {
    @fs.mkdir(output)
  }
  ignore(@artifacts.save_json(output + "/dataset.json", dataset))
  ignore(@artifacts.save_json(output + "/report.json", report))
  ignore(@artifacts.save_json(output + "/summary.json", summary))
}
