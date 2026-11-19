///|
/// Sample Gaussian latents before tanh and actuator clipping, preserving exact log-probability samples.
fn ppo_rollout(
  runtime : @native_physics.Runtime,
  case_json : Json,
  seed : Int32,
  experiment : Json,
  actor : @training.Actor,
  rng : @numeric.Rng,
  std : Double,
  latents : Array[Array[Double]],
) -> (@native_physics.Episode, @native_physics.Trial) raise {
  let case : @native_physics.Case = @json.from_json(case_json)
  let reset_rng = @numeric.Rng::new(seed.to_uint())
  let offset_rng = @numeric.Rng::new(seed.to_uint() ^ 1729U)
  let offset = if case.motion == "pose_offset" {
    let limits = field(case_json, "goal_offset_rad")
    Some(
      @native_physics.pose_offset(
        runtime.joint_names(),
        number(limits, "lower"),
        number(limits, "waist"),
        number(limits, "upper"),
        runtime.joint_names().map(_ => 2 * offset_rng.uniform() - 1),
      ),
    )
  } else {
    None
  }
  let policy = fn(obs : Array[Double], goal : Array[Double]) -> Array[Double] {
    let tape = @numeric.Tape::new()
    let mean = actor.latent_mean(
      tape,
      actor.network.bind(tape),
      tape.vector(obs),
      tape.vector(goal),
    )
    let latent = mean.map(v => v.value + std * rng.normal())
    latents.push(latent)
    actor
    .action_from_latent(tape, tape.vector(latent), tape.vector(goal))
    .map(v => v.value)
  }
  let schedule = joint_sines(
    runtime,
    case_json,
    @numeric.Rng::new(seed.to_uint() ^ 2718U),
  )
  runtime.rollout(
    case,
    seed,
    "policy",
    number(experiment, "duration_s"),
    number(experiment, "control_dt_s"),
    () => reset_rng.normal(),
    fall_height=number(experiment, "fall_height_m"),
    fall_upright=number(experiment, "fall_upright_z"),
    policy~,
    offset?,
    schedule?,
  )
}

///|
/// Position-control servo diagnostic from the first train case, ordered by joint RMS error.
fn baseline_diagnostic(
  runtime : @native_physics.Runtime,
  case_json : Json,
  experiment : Json,
  config : Json,
) -> Json raise {
  let (episode, trial) = rollout(
    runtime,
    case_json,
    0,
    experiment,
    None,
    @numeric.Rng::new(0U),
  )
  guard !episode.steps.is_empty() && !trial.replay.is_empty() else {
    fail("baseline diagnostic has no physical transitions")
  }
  let names = runtime.joint_names()
  let indices = runtime.q_indices()
  let gains = runtime.actuator_gain()
  let rms = Array::make(names.length(), 0.0)
  let joints : Array[Json] = Array::makei(names.length(), j => {
    let mut mean = 0.0
    let mut squared = 0.0
    for step in episode.steps {
      let error = step.next_state[indices[j]] - step.goal[j]
      mean += error
      squared += error * error
    }
    let count = episode.steps.length().to_double()
    rms[j] = (squared / count).sqrt()
    {
      "name": names[j].to_json(),
      "mean_error_rad": (mean / count).to_json(),
      "rms_error_rad": rms[j].to_json(),
      "servo_gain": gains[j].to_json(),
      "max_residual_servo_force": (gains[j] * number(config, "action_delta_rad")).to_json(),
    }
  })
  let order = Array::makei(names.length(), i => i)
  // Stable descending ordering retains model joint order for equal errors.
  for i in 1..<order.length() {
    let selected = order[i]
    let mut position = i
    while position > 0 && rms[order[position - 1]] < rms[selected] {
      order[position] = order[position - 1]
      position -= 1
    }
    order[position] = selected
  }
  let last = trial.replay[trial.replay.length() - 1]
  {
    "case_id": field(case_json, "id"),
    "fall_time_s": trial.simulated_seconds.to_json(),
    "final_root_height_m": last.root_height_m.to_json(),
    "final_upright_z": last.upright_z.to_json(),
    "joints": order.map(i => joints[i]).to_json(),
    "note": "Servo gain times residual range is a setpoint-force increment before saturation/damping, not measured support torque or a proof of the fall cause.",
  }
}

///|
/// Actual-physics PPO outer loop with full-update step reservation and wall-clock budget.
pub async fn run_ppo(
  train_path : String,
  library : String,
  scene : String,
  config_path : String,
  experiment_path : String,
  evaluation_path : String,
  output : String,
  warm_start_directory? : String,
) -> Unit {
  let config = @artifacts.load_json(config_path)
  let experiment = @artifacts.load_json(experiment_path)
  let evaluation = @artifacts.load_json(evaluation_path)
  for
    key in [
      "source_revision", "control_dt_s", "duration_s", "fall_height_m", "fall_upright_z",
    ] {
    guard field(experiment, key) == field(evaluation, key) else {
      fail("training/evaluation runtime differs: " + key)
    }
  }
  let batch = @artifacts.load_window_batch(train_path, "train")
  let windows = @training.windows_from_batch(batch)
  let runtime = @native_physics.Runtime::open(library, scene)
  let (nq, _, _, nu) = runtime.dimensions()
  let body : @training.Body = {
    q_indices: runtime.q_indices(),
    v_state_indices: runtime.v_indices().map(i => nq + i),
    nq,
  }
  let obs_width = batch.observation.length() / (batch.count * batch.horizon)
  let observations = Array::makei(batch.count * batch.horizon, i => {
    Array::makei(obs_width, j => batch.observation[i * obs_width + j])
  })
  let goals = Array::makei(batch.count * batch.horizon, i => {
    Array::makei(nu, j => batch.goal[i * nu + j])
  })
  let states = []
  for w in windows {
    states.append(w.state)
  }
  let obs_stats = @numeric.fit_normalization(observations, 0.1)
  let goal_stats = @numeric.fit_normalization(goals, 0.1)
  let state_stats = @numeric.fit_normalization(states, 0.1)
  let (lower, upper) = runtime.control_bounds()
  let cases : Array[Json] = @json.from_json(field(experiment, "cases"))
  let evaluation_cases : Array[Json] = @json.from_json(
    field(evaluation, "cases"),
  )
  let training_cases = []
  for case in cases {
    if text(case, "split") == "train" {
      training_cases.push(case)
    }
  }
  guard training_cases.length() > 0 else { fail("PPO needs training cases") }
  let seeds : Array[Int32] = @json.from_json(field(config, "seeds"))
  let validation_seeds : Array[Int32] = @json.from_json(
    field(config, "validation_seeds"),
  )
  let test_seeds : Array[Int32] = @json.from_json(field(config, "test_seeds"))
  let gamma = number(config, "gamma")
  let ppo_config : @training.PPOConfig = {
    epochs: integer(config, "epochs"),
    minibatch_size: integer(config, "minibatch_size"),
    raw_action_std: number(config, "raw_action_std"),
    target_kl: number(config, "target_kl"),
    clip_ratio: number(config, "clip_ratio"),
  }
  if !@fs.exists(output) {
    @fs.mkdir(output)
  }
  ignore(
    @artifacts.save_json(
      output + "/baseline-diagnostic.json",
      baseline_diagnostic(runtime, training_cases[0], experiment, config),
    ),
  )
  let normalization_goal_min = Array::makei(nu, j => goals[0][j])
  let normalization_goal_max = normalization_goal_min.copy()
  for goal in goals {
    for j in 0..<nu {
      normalization_goal_min[j] = normalization_goal_min[j].min(goal[j])
      normalization_goal_max[j] = normalization_goal_max[j].max(goal[j])
    }
  }
  let normalization_goal_varying = Array::makei(nu, j => {
      normalization_goal_max[j] - normalization_goal_min[j] > 0.000001
    })
    .filter(v => v)
    .length()
  let mut any_qualified = false
  let runs : Array[Json] = []
  for seed in seeds {
    let rng = @numeric.Rng::new(seed.to_uint())
    let prior = match warm_start_directory {
      Some(dir) =>
        Some(
          @training.load_learning_checkpoint(actor_path(dir, seed), "g1-actor"),
        )
      None => None
    }
    let actor = match prior {
      Some(checkpoint) => {
        let loaded = @training.actor_from_checkpoint(checkpoint)
        guard loaded.body.q_indices == body.q_indices &&
          loaded.body.v_state_indices == body.v_state_indices &&
          loaded.body.nq == body.nq &&
          loaded.action_delta_rad == number(config, "action_delta_rad") &&
          loaded.network.dimensions[1] == integer(config, "hidden_width") &&
          field(checkpoint.metadata, "model_ref") ==
          field(batch.layout, "model_ref") else {
          fail("PPO warm-start body, model or action semantics differ")
        }
        loaded
      }
      None =>
        @training.Actor::new(
          obs_stats,
          goal_stats,
          lower,
          upper,
          number(config, "action_delta_rad"),
          body,
          integer(config, "hidden_width"),
          rng,
        )
    }
    let critic = match prior {
      Some(checkpoint) =>
        @training.critic_from_actor_checkpoint(
          checkpoint,
          nu,
          windows[0].context.length(),
          translation_invariant=optional_bool(
            config, "critic_horizontal_translation_invariant", false,
          ),
        )
      None =>
        @training.Critic::new(
          state_stats,
          nu,
          windows[0].context.length(),
          gamma,
          rng,
          translation_invariant=optional_bool(
            config, "critic_horizontal_translation_invariant", false,
          ),
        )
    }
    let actor_opt = @numeric.Adam::new(
      actor.network.parameters.length(),
      number(config, "actor_learning_rate"),
    )
    guard (critic.value_bound - 3.0 / (1 - gamma)).abs() < 0.00000001 else {
      fail("PPO warm-start changes gamma semantics")
    }
    let critic_opt = @numeric.Adam::new(
      critic.network.parameters.length(),
      number(config, "critic_learning_rate"),
    )
    let initial_actor = actor.network.parameters.copy()
    let (initial, _, _) = evaluate(
      runtime,
      evaluation_cases,
      validation_seeds,
      evaluation,
      Some(actor),
      "validation",
      @numeric.Rng::new(2718U),
    )
    let mut best = initial
    let mut best_actor = actor.network.parameters.copy()
    let mut best_critic = critic.network.parameters.copy()
    let mut selected = 0
    let history : Array[Json] = [
      { "update": 0, "training_steps": 0, "validation": summary_json(initial) },
    ]
    let episodes_per_update = integer(config, "episodes_per_update")
    let ceiling = episodes_per_update *
      @math.round(
        number(experiment, "duration_s") / number(experiment, "control_dt_s"),
      ).to_int()
    let start_time = @async.now()
    let mut training_steps = 0
    let mut collected_episodes = 0
    let mut collection_falls = 0
    let mut last_update = 0
    let mut stop_reason = "updates"
    let goal_min = Array::make(nu, 1.0 / 0.0)
    let goal_max = Array::make(nu, -1.0 / 0.0)
    for update in 1..<=integer(config, "updates") {
      if training_steps + ceiling > integer(config, "max_training_steps") {
        stop_reason = "training-step-budget"
        break
      }
      if (@async.now() - start_time).to_double() / 1000 >=
        number(config, "max_training_seconds") {
        stop_reason = "training-time-budget"
        break
      }
      let episodes = []
      let latents = []
      for i in 0..<episodes_per_update {
        let (episode, trial) = ppo_rollout(
          runtime,
          training_cases[(update + i) % training_cases.length()],
          update * episodes_per_update + i,
          experiment,
          actor,
          rng,
          ppo_config.raw_action_std,
          latents,
        )
        episodes.push(convert_episode(episode))
        collected_episodes += 1
        if trial.failed {
          collection_falls += 1
        }
        training_steps += episode.steps.length()
        for step in episode.steps {
          for j in 0..<nu {
            goal_min[j] = @math.minimum(goal_min[j], step.goal[j])
            goal_max[j] = @math.maximum(goal_max[j], step.goal[j])
          }
        }
      }
      let samples = @training.ppo_samples(
        actor,
        critic,
        episodes,
        latents,
        gamma,
        number(config, "gae_lambda"),
        ppo_config.raw_action_std,
        number(config, "target_height_m"),
      )
      let losses = @training.ppo_optimize(
        actor, critic, actor_opt, critic_opt, samples, ppo_config, rng,
      )
      last_update = update
      if update % integer(config, "evaluate_every") == 0 ||
        update == integer(config, "updates") {
        let (current, _, _) = evaluate(
          runtime,
          evaluation_cases,
          validation_seeds,
          evaluation,
          Some(actor),
          "validation",
          @numeric.Rng::new(2718U),
        )
        history.push({
          "update": update.to_json(),
          "training_steps": training_steps.to_json(),
          "policy_loss": losses.policy_loss.to_json(),
          "value_loss": losses.value_loss.to_json(),
          "maximum_minibatch_kl": losses.maximum_minibatch_kl.to_json(),
          "policy_early_stopped": losses.policy_early_stopped.to_json(),
          "validation": summary_json(current),
        })
        if @training.ranks_above(current, best) {
          best = current
          best_actor = actor.network.parameters.copy()
          best_critic = critic.network.parameters.copy()
          selected = update
        }
      }
    }
    let training_seconds = (@async.now() - start_time).to_double() / 1000
    let metadata : Json = {
      "config": config,
      "algorithm": "ppo-physics",
      "seed": seed.to_json(),
      "training_batch_sha256": batch.digest.to_json(),
      "model_ref": field(batch.layout, "model_ref"),
      "selected_update": selected.to_json(),
      "optimizer_state_restored": false,
    }
    let latest = actor.checkpoint(metadata_update(metadata, last_update))
    critic.put_checkpoint(latest)
    let latest_name = "latest-actor-seed-" + seed.to_string() + ".moon.json"
    ignore(@artifacts.save_checkpoint(output + "/" + latest_name, latest))
    let changed = actor.network.parameters != initial_actor
    @training.restore_parameters(actor.network, best_actor)
    @training.restore_parameters(critic.network, best_critic)
    let selected_checkpoint = actor.checkpoint(metadata)
    critic.put_checkpoint(selected_checkpoint)
    let name = "actor-seed-" + seed.to_string() + ".moon.json"
    let sha = @artifacts.save_checkpoint(
      output + "/" + name,
      selected_checkpoint,
    )
    let restored = @training.actor_from_checkpoint(
      @training.load_learning_checkpoint(
        output + "/" + name,
        "g1-actor",
        expected_sha256=sha,
      ),
    )
    guard restored.predict(observations[0], goals[0]) ==
      actor.predict(observations[0], goals[0]) else {
      fail("PPO checkpoint reload differs")
    }
    let (candidate, episodes, trials) = evaluate(
      runtime,
      evaluation_cases,
      test_seeds,
      evaluation,
      Some(restored),
      "all",
      @numeric.Rng::new(31415U),
    )
    let (baseline, _, baseline_trials) = evaluate(
      runtime,
      evaluation_cases,
      test_seeds,
      evaluation,
      None,
      "all",
      @numeric.Rng::new(31415U),
    )
    ignore(
      @artifacts.save_json(
        output + "/physics-seed-" + seed.to_string() + ".json",
        {
          "candidate": physics_group(candidate, trials),
          "baseline": physics_group(baseline, baseline_trials),
          "trials": trials.to_json(),
        },
      ),
    )
    ignore(
      @artifacts.save_json(
        output + "/candidate-data-seed-" + seed.to_string() + ".json",
        runtime.dataset(
          episodes,
          text(evaluation, "source_revision"),
          dt=number(evaluation, "control_dt_s"),
        ),
      ),
    )
    let varying = Array::makei(nu, j => goal_max[j] - goal_min[j] > 0.000001)
      .filter(v => v)
      .length()
    let input_width = actor.network.dimensions[0]
    guard input_width == obs_width + nu else {
      fail("PPO goal columns differ from the declared observation/goal layout")
    }
    let goal_update_norm = Array::makei(nu, j => {
      let mut squared = 0.0
      for row in 0..<actor.network.dimensions[1] {
        let index = row * input_width + obs_width + j
        let delta = best_actor[index] - initial_actor[index]
        squared += delta * delta
      }
      squared.sqrt()
    })
    let goal_coverage : Json = {
      "varying_channels": varying.to_json(),
      "selected_actor_goal_column_update_l2": goal_update_norm.to_json(),
      "minimum_rad": (if training_steps > 0 { Some(goal_min) } else { None }).to_json(),
      "maximum_rad": (if training_steps > 0 { Some(goal_max) } else { None }).to_json(),
      "channel_names": runtime.joint_names().to_json(),
    }
    let qualified = @training.qualifies(
      candidate,
      optional_number(config, "max_mean_joint_rmse_rad", 1.0 / 0.0),
    )
    any_qualified = any_qualified || qualified
    runs.push({
      "seed": seed.to_json(),
      "selected_update": selected.to_json(),
      "completed_update": last_update.to_json(),
      "training_steps": training_steps.to_json(),
      "training_episodes": collected_episodes.to_json(),
      "training_falls": collection_falls.to_json(),
      "stop_reason": stop_reason.to_json(),
      "training_seconds": training_seconds.to_json(),
      "actor_changed": changed.to_json(),
      "checkpoint": name.to_json(),
      "latest_checkpoint": latest_name.to_json(),
      "checkpoint_sha256": sha.to_json(),
      "history": history.to_json(),
      "candidate": counted_summary(candidate, trials.length()),
      "baseline": counted_summary(baseline, baseline_trials.length()),
      "goal_varying_channels": varying.to_json(),
      "goal_coverage": goal_coverage,
      "qualifies": qualified.to_json(),
      "reload_matches": true,
    })
  }
  ignore(
    @artifacts.save_json(output + "/report.json", {
      "format": "moonrobo.moonbit-ppo-fit.v1",
      "algorithm": "ppo-physics",
      "config": config,
      "experiment": evaluation,
      "collection_experiment": experiment,
      "runs": runs.to_json(),
      "evidence_class": "physics-simulation",
      "evaluation_action_noise_std_rad": 0.0,
      "normalization_batch_sha256": (if warm_start_directory is Some(_) {
        (None : String?)
      } else {
        Some(batch.digest)
      }).to_json(),
      "input_batch_sha256": batch.digest.to_json(),
      "normalization_goal_varying_channels": normalization_goal_varying.to_json(),
      "any_qualified": any_qualified.to_json(),
      "comparison_limit": "Shared actor/critic architecture and step reward; no matched total-budget, initialization-data-cost or learning-speed claim.",
      "physical_execution_allowed": false,
      "parity_status": "awaiting-python-comparison",
    }),
  )
}
