///|
fn field(value : Json, key : String) -> Json raise {
  guard value is Object(fields) && fields.get(key) is Some(v) else {
    fail("missing policy configuration: " + key)
  }
  v
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
fn optional_number(
  value : Json,
  key : String,
  fallback : Double,
) -> Double raise {
  guard value is Object(fields) else { fail("configuration must be object") }
  match fields.get(key) {
    Some(v) => @json.from_json(v)
    None => fallback
  }
}

///|
fn optional_bool(value : Json, key : String, fallback : Bool) -> Bool raise {
  guard value is Object(fields) else { fail("configuration must be object") }
  match fields.get(key) {
    Some(v) => @json.from_json(v)
    None => fallback
  }
}

///|
fn text(value : Json, key : String) -> String raise {
  @json.from_json(field(value, key))
}

///|
fn convert_episode(episode : @native_physics.Episode) -> @training.Episode {
  {
    id: episode.id,
    split: episode.split,
    context: episode.context,
    steps: episode.steps.map(s => {
      time_s: s.time_s,
      state: s.state,
      observation: s.observation,
      applied_action: s.applied_action,
      next_state: s.next_state,
      goal: s.goal,
      terminated: s.terminated,
      truncated: s.truncated,
    }),
  }
}

///|
fn joint_sines(
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
fn rollout(
  runtime : @native_physics.Runtime,
  case_json : Json,
  seed : Int32,
  experiment : Json,
  actor : @training.Actor?,
  _rng : @numeric.Rng,
  action_noise_std~ : Double = 0.0,
) -> (@native_physics.Episode, @native_physics.Trial) raise {
  let case : @native_physics.Case = @json.from_json(case_json)
  // Reset/command draws belong to this declared physical episode, independent
  // of policy survival or training/optimizer RNG consumption in other episodes.
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
  let policy : ((Array[Double], Array[Double]) -> Array[Double])? = actor.map(a => {
    (obs, goal) => a.predict(obs, goal)
  })
  let schedule = joint_sines(
    runtime,
    case_json,
    @numeric.Rng::new(seed.to_uint() ^ 2718U),
  )
  runtime.rollout(
    case,
    seed,
    if actor is Some(_) {
      "policy"
    } else {
      "position"
    },
    number(experiment, "duration_s"),
    number(experiment, "control_dt_s"),
    () => reset_rng.normal(),
    fall_height=number(experiment, "fall_height_m"),
    fall_upright=number(experiment, "fall_upright_z"),
    action_noise_std~,
    policy?,
    offset?,
    schedule?,
  )
}

///|
pub fn evaluate(
  runtime : @native_physics.Runtime,
  cases : Array[Json],
  seeds : Array[Int32],
  experiment : Json,
  actor : @training.Actor?,
  split : String,
  rng : @numeric.Rng,
) -> (
  @training.PhysicsSummary,
  Array[@native_physics.Episode],
  Array[@native_physics.Trial],
) raise {
  let episodes = []
  let trials = []
  let mut falls = 0
  let mut survival_s = 0.0
  let mut joint_rmse_rad = 0.0
  for case in cases {
    if split != "all" && text(case, "split") != split {
      continue
    }
    for seed in seeds {
      let (episode, trial) = rollout(
        runtime, case, seed, experiment, actor, rng,
      )
      episodes.push(episode)
      trials.push(trial)
      if trial.failed {
        falls += 1
      }
      survival_s += trial.simulated_seconds
      joint_rmse_rad += trial.joint_rmse_rad
    }
  }
  guard trials.length() > 0 else { fail("no physics evaluation cases") }
  (
    {
      falls,
      survival_s: survival_s / trials.length().to_double(),
      joint_rmse_rad: joint_rmse_rad / trials.length().to_double(),
    },
    episodes,
    trials,
  )
}

///|
fn summary_json(summary : @training.PhysicsSummary) -> Json {
  {
    "falls": summary.falls.to_json(),
    "mean_survival_s": summary.survival_s.to_json(),
    "mean_joint_rmse_rad": summary.joint_rmse_rad.to_json(),
  }
}

///|
fn counted_summary(summary : @training.PhysicsSummary, trials : Int32) -> Json {
  let result = summary_json(summary)
  if result is Object(fields) {
    fields["trials"] = trials.to_json()
  }
  result
}

///|
fn physics_group(
  summary : @training.PhysicsSummary,
  trials : Array[@native_physics.Trial],
) -> Json {
  {
    "summary": counted_summary(summary, trials.length()),
    "trials": trials.to_json(),
  }
}

///|
fn metadata_update(metadata : Json, update : Int32) -> Json {
  match metadata {
    Object(fields) => {
      let fields = fields.copy()
      fields["selected_update"] = update.to_json()
      Json::object(fields)
    }
    _ => metadata
  }
}

///|
async fn actor_path(directory : String, seed : Int32) -> String {
  let base = directory + "/actor-seed-" + seed.to_string()
  if @fs.exists(base + ".moon.json") {
    base + ".moon.json"
  } else {
    base + ".pt"
  }
}

///|
/// Canonical native parameter digest; its encoding differs from Torch's named Float32 byte stream.
fn policy_parameter_digest(parameters : Array[Double]) -> String {
  @artifacts.sha256(@utf8.encode(parameters.to_json().stringify()))
}

///|
fn policy_model_metrics(metrics : @training.DynamicsMetrics) -> Json {
  let late_beats : Bool? = match
    (metrics.late_mse, metrics.late_persistence_mse) {
    (Some(a), Some(b)) => Some(a < b)
    _ => None
  }
  {
    "windows": metrics.windows.to_json(),
    "normalized_state_mse": metrics.mse.to_json(),
    "persistence_mse": metrics.persistence_mse.to_json(),
    "beats_persistence": (metrics.mse < metrics.persistence_mse).to_json(),
    "per_step_normalized_state_mse": metrics.per_step_mse.to_json(),
    "per_step_persistence_mse": metrics.persistence_per_step_mse.to_json(),
    "after_two_seconds": {
      "windows": metrics.late_windows.to_json(),
      "normalized_state_mse": metrics.late_mse.to_json(),
      "persistence_mse": metrics.late_persistence_mse.to_json(),
      "beats_persistence": late_beats.to_json(),
    },
  }
}

///|
fn policy_model_metadata(
  metadata : Json,
  seed : Int32,
  update : Int32,
  round : Int32,
  physics_sha : String,
) -> Json raise {
  guard metadata is Object(fields) else {
    fail("world-model metadata must be object")
  }
  let fields = fields.copy()
  fields["seed"] = seed.to_json()
  fields["selected_update"] = update.to_json()
  fields["online_model_round"] = round.to_json()
  fields["online_physics_sha256"] = physics_sha.to_json()
  fields["normalization_source"] = "initial-training-windows-frozen".to_json()
  Json::object(fields)
}

///|
fn calibrate_physical_critic(
  runtime : @native_physics.Runtime,
  actor : @training.Actor,
  critic : @training.Critic,
  optimizer : @numeric.Adam,
  online : @training.OnlineDynamics?,
  config : Json,
  collection : Json,
  seed : Int32,
  actor_update : Int32,
  rng : @numeric.Rng,
  physics_rows : Array[Json],
) -> Double raise {
  let started = @async.now()
  let actor_digest = policy_parameter_digest(actor.network.parameters)
  let collected = []
  let physical_episodes = []
  let cases : Array[Json] = @json.from_json(field(collection, "cases"))
  let refresh = integer(config, "critic_physics_refresh_every")
  guard refresh > 0 else {
    fail("critic physics refresh interval must be positive")
  }
  let reset_seed = integer(config, "critic_collect_seed_base") +
    seed * 10000 +
    actor_update / refresh
  for case in cases {
    if text(case, "split") != "train" {
      continue
    }
    guard ["stand", "pose_offset"].contains(text(case, "motion")) else {
      fail("physics critic calibration requires constant-goal cases")
    }
    let (episode, _) = rollout(
      runtime,
      case,
      reset_seed,
      collection,
      Some(actor),
      rng,
    )
    physical_episodes.push(episode)
    collected.push(convert_episode(episode))
  }
  guard !collected.is_empty() else {
    fail("physics critic calibration needs train episodes")
  }
  let points = @training.physical_value_points(
    actor,
    critic,
    collected,
    number(config, "gamma"),
    number(config, "target_height_m"),
  )
  let tails = collected.map(episode => {
    let last = episode.steps[episode.steps.length() - 1]
    if last.truncated {
      critic.predict(last.next_state, last.goal, episode.context)
    } else {
      0.0
    }
  })
  let collection_seconds = (@async.now() - started).to_double() / 1000
  let model_update : Json = match online {
    Some(updater) => {
      let frozen = [
        updater.model.state_stats.mean,
        updater.model.state_stats.scale,
        updater.model.action_stats.mean,
        updater.model.action_stats.scale,
        updater.model.context_stats.mean,
        updater.model.context_stats.scale,
      ].map(row => row.copy())
      let result = updater.update(collected, number(collection, "control_dt_s"))
      guard [
          updater.model.state_stats.mean,
          updater.model.state_stats.scale,
          updater.model.action_stats.mean,
          updater.model.action_stats.scale,
          updater.model.context_stats.mean,
          updater.model.context_stats.scale,
        ] ==
        frozen else {
        fail("online round changed frozen normalization")
      }
      {
        "round": result.round.to_json(),
        "optimizer_steps": result.optimizer_steps.to_json(),
        "recent_windows": result.recent_windows.to_json(),
        "training_loss": result.training_loss.to_json(),
        "normalization_unchanged": true,
      }
    }
    None => Json::null()
  }
  let mae = fn() -> Double {
    let mut total = 0.0
    for point in points {
      total += (critic.predict(point.state, point.goal, point.context) -
      point.target).abs()
    }
    total / points.length().to_double()
  }
  let before = mae()
  let mut loss = 0.0
  for _ in 0..<integer(config, "critic_physics_fit_steps") {
    let mini = Array::makei(integer(config, "critic_physics_minibatch_size"), _ => {
      points[rng.index(points.length())]
    })
    loss = critic.update(optimizer, mini)
  }
  let calibration : Json = {
    "actor_update": actor_update.to_json(),
    "reset_seed": reset_seed.to_json(),
    "actor_state_sha256": actor_digest.to_json(),
    "actor_state_digest_encoding": "MoonBit canonical float64 parameter JSON",
    "episodes": collected.length().to_json(),
    "transitions": points.length().to_json(),
    "falls": collected
    .filter(e => e.steps[e.steps.length() - 1].terminated)
    .length()
    .to_json(),
    "time_limits": collected
    .filter(e => e.steps[e.steps.length() - 1].truncated)
    .length()
    .to_json(),
    "collection_seconds": collection_seconds.to_json(),
    "total_seconds": ((@async.now() - started).to_double() / 1000).to_json(),
    "training_mae_before": before.to_json(),
    "training_mae_after": mae().to_json(),
    "optimizer_steps": integer(config, "critic_physics_fit_steps").to_json(),
    "model_update": model_update,
  }
  physics_rows.push({
    "format": "moonrobo.g1-critic-physics-batch.v1",
    "actor_update": actor_update.to_json(),
    "actor_state_sha256": actor_digest.to_json(),
    "reset_seed": reset_seed.to_json(),
    "dataset": runtime.dataset(
      physical_episodes,
      text(collection, "source_revision"),
      dt=number(collection, "control_dt_s"),
    ),
    "soft_return_targets": points.map(p => p.target).to_json(),
    "tail_bootstrap_values": tails.to_json(),
    "calibration": calibration,
  })
  loss
}

///|
/// Native end-to-end actor/critic experiment. Explicit MuJoCo library path avoids Python runtime discovery.
pub async fn run_policy(
  train_path : String,
  dynamics_path : String,
  library : String,
  scene : String,
  config_path : String,
  experiment_path : String,
  output : String,
  warm_start_directory? : String,
  policy_replay_path? : String,
) -> Unit {
  let config = @json.parse(@utf8.decode(@fs.read_file(config_path).binary()))
  let experiment = @json.parse(
    @utf8.decode(@fs.read_file(experiment_path).binary()),
  )
  let model_training_batch = @artifacts.load_window_batch(train_path, "train")
  let model_checkpoint = @training.load_learning_checkpoint(
    dynamics_path, "residual-dynamics",
  )
  guard field(model_checkpoint.metadata, "layout") ==
    model_training_batch.layout &&
    field(model_checkpoint.metadata, "training_batch_sha256") ==
    model_training_batch.digest.to_json() else {
    fail("policy dynamics layout differs from input batch")
  }
  let batch = match policy_replay_path {
    Some(path) => {
      let replay = @artifacts.load_window_batch(path, "train")
      model_training_batch.compatible(replay, require_dataset_id=false)
      for key in ["observation_axes", "goal_axes"] {
        guard field(model_training_batch.layout, key) ==
          field(replay.layout, key) else {
          fail("policy replay axes differ: " + key)
        }
      }
      replay
    }
    None => model_training_batch
  }
  let windows = @training.windows_from_batch(batch)
  let runtime = @native_physics.Runtime::open(library, scene)
  let (nq, _, _, nu) = runtime.dimensions()
  let body : @training.Body = {
    q_indices: runtime.q_indices(),
    v_state_indices: runtime.v_indices().map(i => nq + i),
    nq,
  }
  let obs_width = batch.observation.length() / (batch.count * batch.horizon)
  let goals = Array::makei(batch.count * batch.horizon, i => {
    Array::makei(nu, j => batch.goal[i * nu + j])
  })
  let observations = Array::makei(batch.count * batch.horizon, i => {
    Array::makei(obs_width, j => batch.observation[i * obs_width + j])
  })
  // Match the source guard before using recorded states as imagined starts.
  guard obs_width >= nu else {
    fail("policy observation omits previous controls")
  }
  for i in 0..<@math.minimum(batch.count, 64) {
    let actual = observations[i * batch.horizon]
    let tape = @numeric.Tape::new()
    let previous = Array::makei(nu, j => actual[actual.length() - nu + j])
    let reconstructed = @training.observation(
      tape,
      tape.vector(windows[i].state[0]),
      tape.vector(previous),
      body,
    )
    guard reconstructed.length() == actual.length() else {
      fail("imagined and physics observation widths disagree")
    }
    for j in 0..<actual.length() {
      guard @numeric.finite(reconstructed[j].value) &&
        @numeric.finite(actual[j]) &&
        (reconstructed[j].value - actual[j]).abs() <=
        0.00001 + 0.00001 * actual[j].abs() else {
        fail("imagined and physics observations disagree")
      }
    }
  }
  let obs_stats = @numeric.fit_normalization(observations, 0.1)
  let goal_stats = @numeric.fit_normalization(goals, 0.1)
  let (lower, upper) = runtime.control_bounds()
  let cases : Array[Json] = @json.from_json(field(experiment, "cases"))
  let validation_seeds : Array[Int32] = @json.from_json(
    field(config, "validation_seeds"),
  )
  let test_seeds : Array[Int32] = @json.from_json(field(config, "test_seeds"))
  let seeds : Array[Int32] = @json.from_json(field(config, "seeds"))
  let training_cases = cases.filter(c => try! (text(c, "split") == "train"))
  guard training_cases.length() > 0 else {
    fail("policy experiment needs training cases")
  }
  let gamma = number(config, "gamma")
  let rollout_config : @training.RolloutConfig = {
    horizon: integer(config, "horizon"),
    gamma,
    target_height: number(config, "target_height_m"),
    bootstrap: optional_bool(config, "actor_critic_bootstrap", true),
  }
  let online_updates = optional_number(config, "online_model_updates", 0).to_int()
  let critic_source = match config {
    Object(fields) =>
      match fields.get("critic_training_source") {
        Some(v) => @json.from_json(v)
        None => "imagined-gae"
      }
    _ => "imagined-gae"
  }
  guard ["imagined-gae", "physics-returns", "frozen"].contains(critic_source) else {
    fail("unknown critic training source")
  }
  guard online_updates == 0 || critic_source == "physics-returns" else {
    fail("online dynamics requires physical collection")
  }
  let collection_experiment = if critic_source == "physics-returns" {
    let collection_path = text(config, "critic_collection_experiment")
    @artifacts.load_json(collection_path)
  } else {
    experiment
  }
  let model_batches : Map[String, @artifacts.WindowBatch] = {}
  let dynamics_directory = if online_updates > 0 {
    for
      (split, key) in [
        ("validation", "model_validation_batch"),
        ("test", "model_test_batch"),
      ] {
      let model_batch = @artifacts.load_window_batch(text(config, key), split)
      batch.compatible(model_batch)
      model_batches[split] = model_batch
    }
    match config {
      Object(fields) =>
        match fields.get("online_dynamics_output") {
          Some(String(path)) => path
          _ => output
        }
      _ => output
    }
  } else {
    output
  }
  if !@fs.exists(output) {
    @fs.mkdir(output)
  }
  if !@fs.exists(dynamics_directory) {
    @fs.mkdir(dynamics_directory, recursive=true)
  }
  let input_dynamics_sha = @artifacts.sha256(
    @fs.read_file(dynamics_path).binary(),
  )
  let runs : Array[Json] = []
  for seed in seeds {
    let rng = @numeric.Rng::new(seed.to_uint())
    let dynamics = @training.dynamics_from_checkpoint(model_checkpoint)
    let prior = match warm_start_directory {
      Some(directory) =>
        Some(
          @training.load_learning_checkpoint(
            actor_path(directory, seed),
            "g1-actor",
          ),
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
          fail("warm-start actor body, model or residual semantics differ")
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
          dynamics.context_stats.mean.length(),
          translation_invariant=optional_bool(
            config, "critic_horizontal_translation_invariant", false,
          ),
        )
      None =>
        @training.Critic::new(
          dynamics.state_stats,
          nu,
          dynamics.context_stats.mean.length(),
          gamma,
          rng,
          translation_invariant=optional_bool(
            config, "critic_horizontal_translation_invariant", false,
          ),
        )
    }
    let initialization : Json = match prior {
      Some(checkpoint) => {
        let path = actor_path(warm_start_directory.unwrap(), seed)
        let encoding_changed = optional_bool(
            config, "critic_horizontal_translation_invariant", false,
          ) !=
          optional_bool(
            field(checkpoint.metadata, "config"),
            "critic_horizontal_translation_invariant",
            false,
          )
        {
          "mode": "weights-only-warm-start",
          "checkpoint": path.to_json(),
          "sha256": @artifacts.sha256(@fs.read_file(path).binary()).to_json(),
          "prior_selected_update": field(checkpoint.metadata, "selected_update"),
          "critic_encoding_changed": encoding_changed.to_json(),
        }
      }
      None => { "mode": "zero-residual" }
    }
    let initial_actor_parameters = actor.network.parameters.copy()
    let initial_critic_parameters = critic.network.parameters.copy()
    let initial_model_parameters = dynamics.network.parameters.copy()
    let frozen_units = [
      dynamics.state_stats.mean,
      dynamics.state_stats.scale,
      dynamics.action_stats.mean,
      dynamics.action_stats.scale,
      dynamics.context_stats.mean,
      dynamics.context_stats.scale,
    ].map(row => row.copy())
    let online = if online_updates > 0 {
      Some(
        @training.OnlineDynamics::new(
          dynamics,
          windows,
          integer(config, "online_replay_windows"),
          integer(config, "batch_size"),
          online_updates,
          number(config, "online_model_learning_rate"),
          (integer(config, "online_sampling_seed") + seed).to_uint(),
        ),
      )
    } else {
      None
    }
    guard (critic.value_bound - 3.0 / (1 - gamma)).abs() < 0.00000001 else {
      fail("warm start changes critic gamma semantics")
    }
    let actor_optimizer = @numeric.Adam::new(
      actor.network.parameters.length(),
      number(config, "actor_learning_rate"),
    )
    let critic_optimizer = @numeric.Adam::new(
      critic.network.parameters.length(),
      number(config, "critic_learning_rate"),
    )
    let physics_rows : Array[Json] = []
    let training_started = @async.now()
    if critic_source == "physics-returns" {
      ignore(
        calibrate_physical_critic(
          runtime, actor, critic, critic_optimizer, online, config, collection_experiment,
          seed, 0, rng, physics_rows,
        ),
      )
    }
    let (initial, _, _) = evaluate(
      runtime,
      cases,
      validation_seeds,
      experiment,
      Some(actor),
      "validation",
      @numeric.Rng::new(2718U),
    )
    let mut best = initial
    let mut best_actor = actor.network.parameters.copy()
    let mut best_critic = critic.network.parameters.copy()
    let mut best_dynamics = dynamics.network.parameters.copy()
    let mut best_model_round = match online {
      Some(updater) => updater.rounds
      None => 0
    }
    let mut selected_update = 0
    let history : Array[Json] = [
      { "update": 0, "validation": summary_json(initial) },
    ]
    let updates = integer(config, "updates")
    for update in 1..<=updates {
      let mut critic_loss = 0.0
      if critic_source == "physics-returns" &&
        update > 1 &&
        (update - 1) % integer(config, "critic_physics_refresh_every") == 0 {
        critic_loss = calibrate_physical_critic(
          runtime,
          actor,
          critic,
          critic_optimizer,
          online,
          config,
          collection_experiment,
          seed,
          update - 1,
          rng,
          physics_rows,
        )
      }
      let indices = Array::makei(integer(config, "batch_size"), _ => {
        rng.index(windows.length())
      })
      let starts : Array[@training.ActorStart] = indices.map(i => {
        let w = windows[i]
        let obs = observations[i * batch.horizon]
        {
          state: w.state[0],
          previous: Array::makei(nu, j => obs[obs.length() - nu + j]),
          goal: goals[i * batch.horizon],
          context: w.context,
        }
      })
      let value_points = if critic_source == "imagined-gae" {
        @training.imagined_value_points(
          dynamics,
          actor,
          critic,
          starts,
          rollout_config,
          number(config, "gae_lambda"),
        )
      } else {
        []
      }
      let step_model_parameters = dynamics.network.parameters.copy()
      let actor_result = @training.imagined_actor_update(
        dynamics, actor, critic, actor_optimizer, starts, rollout_config,
      )
      guard dynamics.network.parameters == step_model_parameters else {
        fail("actor update changed frozen world-model parameters")
      }
      if critic_source == "imagined-gae" {
        for _ in 0..<integer(config, "critic_epochs") {
          let ids = Array::makei(value_points.length(), i => i)
          rng.shuffle(ids)
          let chunk_size = (ids.length() + 3) / 4
          for start = 0; start < ids.length(); start = start + chunk_size {
            let count = if start + chunk_size > ids.length() {
              ids.length() - start
            } else {
              chunk_size
            }
            critic_loss = critic.update(
              critic_optimizer,
              Array::makei(count, j => value_points[ids[start + j]]),
            )
          }
        }
      }
      guard actor_result.objective.abs() <= critic.value_bound + 0.001 else {
        fail("imagined return exceeds discounted reward bound")
      }
      let additional_evaluation = match config {
        Object(fields) =>
          match fields.get("evaluation_updates") {
            Some(Array(values)) => values.contains(update.to_json())
            _ => false
          }
        _ => false
      }
      if update % integer(config, "evaluate_every") == 0 ||
        update == updates ||
        additional_evaluation {
        let (current, _, _) = evaluate(
          runtime,
          cases,
          validation_seeds,
          experiment,
          Some(actor),
          "validation",
          @numeric.Rng::new(2718U),
        )
        let calibration = if physics_rows.is_empty() {
          Json::null()
        } else {
          field(physics_rows[physics_rows.length() - 1], "calibration")
        }
        history.push({
          "update": update.to_json(),
          "actor_loss": actor_result.loss.to_json(),
          "imagined_return": actor_result.objective.to_json(),
          "actor_gradient_norm": actor_result.gradient_norm.to_json(),
          "critic_loss": (if critic_source == "imagined-gae" {
            Some(critic_loss)
          } else {
            None
          }).to_json(),
          "physics_calibration": calibration,
          "validation": summary_json(current),
        })
        if @training.ranks_above(current, best) {
          best = current
          selected_update = update
          best_actor = actor.network.parameters.copy()
          best_critic = critic.network.parameters.copy()
          best_dynamics = dynamics.network.parameters.copy()
          best_model_round = match online {
            Some(updater) => updater.rounds
            None => 0
          }
        }
      }
    }
    let training_seconds = (@async.now() - training_started).to_double() / 1000
    guard online is Some(_) ||
      dynamics.network.parameters == initial_model_parameters else {
      fail("policy optimization changed frozen world model")
    }
    guard critic_source != "frozen" ||
      critic.network.parameters == initial_critic_parameters else {
      fail("actor optimization changed frozen critic")
    }
    guard [
        dynamics.state_stats.mean,
        dynamics.state_stats.scale,
        dynamics.action_stats.mean,
        dynamics.action_stats.scale,
        dynamics.context_stats.mean,
        dynamics.context_stats.scale,
      ] ==
      frozen_units else {
      fail("online adaptation changed frozen normalization")
    }
    let physics_payload : Json = if physics_rows.is_empty() {
      Json::null()
    } else {
      let file = "critic-physics-seed-" + seed.to_string() + ".jsonl.gz"
      let sha = @artifacts.save_jsonl(output + "/" + file, physics_rows)
      {
        "file": file.to_json(),
        "sha256": sha.to_json(),
        "batches": physics_rows
        .map(row => try! field(row, "calibration"))
        .to_json(),
      }
    }
    let actor_changed = actor.network.parameters != initial_actor_parameters
    let latest_model_parameters = dynamics.network.parameters.copy()
    let online_evidence : Json = match online {
      Some(updater) => {
        let physics_sha = text(physics_payload, "sha256")
        let selected_name = "dynamics-seed-" + seed.to_string() + ".moon.json"
        let latest_name = "latest-dynamics-seed-" +
          seed.to_string() +
          ".moon.json"
        let latest_sha = @artifacts.save_checkpoint(
          dynamics_directory + "/" + latest_name,
          dynamics.checkpoint(
            policy_model_metadata(
              model_checkpoint.metadata,
              seed,
              updates,
              updater.rounds,
              physics_sha,
            ),
          ),
        )
        @training.restore_parameters(dynamics.network, best_dynamics)
        let selected_sha = @artifacts.save_checkpoint(
          dynamics_directory + "/" + selected_name,
          dynamics.checkpoint(
            policy_model_metadata(
              model_checkpoint.metadata,
              seed,
              selected_update,
              best_model_round,
              physics_sha,
            ),
          ),
        )
        let validation_windows = @training.windows_from_batch(
          model_batches["validation"],
        )
        let test_windows = @training.windows_from_batch(model_batches["test"])
        let metrics : Json = {
          "validation": policy_model_metrics(
            dynamics.evaluate(validation_windows),
          ),
          "test": policy_model_metrics(dynamics.evaluate(test_windows)),
        }
        let before_probe = dynamics.network.parameters.copy()
        let probe = dynamics.gradient_probe(validation_windows[0])
        guard dynamics.network.parameters == before_probe else {
          fail("online model gradient probe changed parameters")
        }
        let reloaded = @training.dynamics_from_checkpoint(
          @training.load_learning_checkpoint(
            dynamics_directory + "/" + selected_name,
            "residual-dynamics",
            expected_sha256=selected_sha,
          ),
        )
        guard policy_model_metrics(reloaded.evaluate(test_windows)) ==
          field(metrics, "test") else {
          fail("selected online model reload changed predictions")
        }
        @training.restore_parameters(dynamics.network, latest_model_parameters)
        {
          "seed": seed.to_json(),
          "checkpoint": selected_name.to_json(),
          "latest_checkpoint": latest_name.to_json(),
          "directory": dynamics_directory.to_json(),
          "selected_sha256": selected_sha.to_json(),
          "latest_sha256": latest_sha.to_json(),
          "selected_model_round": best_model_round.to_json(),
          "completed_model_rounds": updater.rounds.to_json(),
          "model_optimizer_steps": updater.optimizer_steps.to_json(),
          "metrics": metrics,
          "gradient_probe": {
            "passed": probe.passed.to_json(),
            "horizon": validation_windows[0].action.length().to_json(),
            "action_gradient_norm": probe.action_gradient_norm.to_json(),
            "state_gradient_norm": probe.state_gradient_norm.to_json(),
            "analytic_directional": probe.analytic_directional.to_json(),
            "finite_difference_directional": probe.finite_difference_directional.to_json(),
            "frozen_parameter_gradients": true,
          },
          "reload_matches": true,
          "normalization_source": "initial-training-windows-frozen",
        }
      }
      None => Json::null()
    }
    let metadata : Json = {
      "config": config,
      "body": {
        "q_indices": body.q_indices.to_json(),
        "v_state_indices": body.v_state_indices.to_json(),
        "nq": nq.to_json(),
      },
      "seed": seed.to_json(),
      "selected_update": selected_update.to_json(),
      "training_batch_sha256": batch.digest.to_json(),
      "model_ref": field(batch.layout, "model_ref"),
      "numeric_backend": "pure-moonbit-float64-reverse-ad",
      "checkpoint_selection": "validation-physics-only",
      "initialization": initialization,
      "online_dynamics": online_evidence,
    }
    let latest_name = "latest-actor-seed-" + seed.to_string() + ".moon.json"
    let latest_checkpoint = actor.checkpoint(metadata_update(metadata, updates))
    critic.put_checkpoint(latest_checkpoint)
    if online is Some(_) {
      match latest_checkpoint.metadata {
        Object(fields) =>
          fields["paired_dynamics_sha256"] = field(
            online_evidence, "latest_sha256",
          )
        _ => ()
      }
    }
    ignore(
      @artifacts.save_checkpoint(output + "/" + latest_name, latest_checkpoint),
    )
    @training.restore_parameters(actor.network, best_actor)
    @training.restore_parameters(critic.network, best_critic)
    @training.restore_parameters(dynamics.network, best_dynamics)
    let checkpoint = actor.checkpoint(metadata)
    critic.put_checkpoint(checkpoint)
    if online is Some(_) {
      match checkpoint.metadata {
        Object(fields) =>
          fields["paired_dynamics_sha256"] = field(
            online_evidence, "selected_sha256",
          )
        _ => ()
      }
    }
    let name = "actor-seed-" + seed.to_string() + ".moon.json"
    let sha = @artifacts.save_checkpoint(output + "/" + name, checkpoint)
    let restored = @training.actor_from_checkpoint(
      @training.load_learning_checkpoint(
        output + "/" + name,
        "g1-actor",
        expected_sha256=sha,
      ),
    )
    for i in 0..<@math.minimum(batch.count, 8) {
      guard restored.predict(
          observations[i * batch.horizon],
          goals[i * batch.horizon],
        ) ==
        actor.predict(observations[i * batch.horizon], goals[i * batch.horizon]) else {
        fail("actor checkpoint reload differs")
      }
    }
    let (candidate, episodes, trials) = evaluate(
      runtime,
      cases,
      test_seeds,
      experiment,
      Some(restored),
      "all",
      @numeric.Rng::new(31415U),
    )
    let (baseline, _, baseline_trials) = evaluate(
      runtime,
      cases,
      test_seeds,
      experiment,
      None,
      "all",
      @numeric.Rng::new(31415U),
    )
    @fs.write_file(
      output + "/candidate-data-seed-" + seed.to_string() + ".json",
      @utf8.encode(
        runtime
        .dataset(
          episodes,
          text(experiment, "source_revision"),
          dt=number(experiment, "control_dt_s"),
        )
        .stringify(),
      ),
      create_mode=CreateOrTruncate,
    )
    let physics_report : Json = {
      "baseline": physics_group(baseline, baseline_trials),
      "candidate": physics_group(candidate, trials),
      "trials": trials.to_json(),
    }
    @fs.write_file(
      output + "/physics-seed-" + seed.to_string() + ".json",
      @utf8.encode(physics_report.stringify()),
      create_mode=CreateOrTruncate,
    )
    runs.push({
      "seed": seed.to_json(),
      "selected_update": selected_update.to_json(),
      "training_seconds": training_seconds.to_json(),
      "initialization": initialization,
      "actor_changed": actor_changed.to_json(),
      "dynamics_unchanged": (online is None).to_json(),
      "critic_unchanged": (if critic_source == "frozen" {
        Some(true)
      } else {
        None
      }).to_json(),
      "world_model_frozen_within_actor_updates": true,
      "online_dynamics": online_evidence,
      "critic_training_source": critic_source.to_json(),
      "critic_physics": physics_payload,
      "checkpoint": name.to_json(),
      "checkpoint_sha256": sha.to_json(),
      "latest_checkpoint": latest_name.to_json(),
      "history": history.to_json(),
      "candidate": counted_summary(candidate, trials.length()),
      "baseline": counted_summary(baseline, baseline_trials.length()),
      "reload_matches": true,
      "qualifies": @training.qualifies(
        candidate,
        optional_number(config, "max_mean_joint_rmse_rad", 1.0 / 0.0),
      ).to_json(),
    })
  }
  if online_updates > 0 {
    let inputs : Map[String, Json] = {}
    for split, batch in model_batches {
      inputs[split] = batch.digest.to_json()
    }
    let all_passed = runs.all(run => {
      try! (field(
        field(field(run, "online_dynamics"), "gradient_probe"),
        "passed",
      ) ==
      true.to_json() &&
      field(
        field(field(field(run, "online_dynamics"), "metrics"), "test"),
        "beats_persistence",
      ) ==
      true.to_json())
    })
    let fit_report = if dynamics_directory == output {
      "online-dynamics-report.json"
    } else {
      "report.json"
    }
    ignore(
      @artifacts.save_json(dynamics_directory + "/" + fit_report, {
        "format": "moonrobo.moonbit-online-dynamics-fit.v1",
        "evidence_class": "learned-model-prediction",
        "config": config,
        "initial_dynamics_sha256": input_dynamics_sha.to_json(),
        "normalization_source": "initial-training-windows-frozen",
        "selection_source": "paired-policy-validation",
        "inputs": Json::object(inputs),
        "runs": runs.map(run => try! field(run, "online_dynamics")).to_json(),
        "all_passed": all_passed.to_json(),
      }),
    )
  }
  let report : Json = {
    "format": "moonrobo.moonbit-policy-fit.v1",
    "config": config,
    "experiment": experiment,
    "runs": runs.to_json(),
    "evidence_class": "physics-simulation",
    "checkpoint_selection": "validation-physics-only",
    "dynamics_sha256": input_dynamics_sha.to_json(),
    "dynamics_training_batch_sha256": field(
      model_checkpoint.metadata,
      "training_batch_sha256",
    ),
    "policy_replay_sha256": batch.digest.to_json(),
    "provider_sha256": @artifacts.sha256(
      @fs.read_file("src/learning_training/physics/runner.mbt").binary(),
    ).to_json(),
    "preserved_python_provider_sha256": @artifacts.sha256(
      @fs.read_file("providers/motion_learning/policy.py").binary(),
    ).to_json(),
    "any_qualified": runs
    .any(run => try! (field(run, "qualifies") == true.to_json()))
    .to_json(),
    "physical_execution_allowed": false,
    "parity_status": "awaiting-python-comparison",
  }
  @fs.write_file(
    output + "/report.json",
    @utf8.encode(report.stringify(indent=2)),
    create_mode=CreateOrTruncate,
  )
}
