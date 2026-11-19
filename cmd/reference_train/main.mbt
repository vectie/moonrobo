///|
struct Config {
  references : String
  actor_checkpoint : String
  actor_sha256 : String
  library : String
  scene : String
  output : String
  seed : UInt32
  cycles : Int32
  origins : Array[Int32]
  method : String
  gamma : Double
  gae_lambda : Double
  raw_action_std : Double
  imagination_horizon : Int32
  critic_updates : Int32
  critic_batch_size : Int32
  critic_learning_rate : Double
  model_updates : Int32
  model_batch_size : Int32
  model_width : Int32
  model_window : Int32
  model_replay_windows : Int32
  model_learning_rate : Double
  normalization_floor : Double
  actor_steps : Int32
  actor_batch_size : Int32
  actor_learning_rate : Double
  actor_trajectory_states : Bool
  actor_critic_tail : Bool
  ppo_epochs : Int32
  ppo_minibatch_size : Int32
  ppo_clip : Double
  ppo_target_kl : Double
} derive(FromJson)

///|
async fn main {
  let args = @env.args()
  if (args.length() == 10 || args.length() == 11) && args[1] == "study" {
    let runtime = @physics.Runtime::open(args[6], args[7])
    let report = @reference.run_learning_study(
      args[2],
      args[3],
      args[4],
      args[5],
      runtime,
      args[8],
      args[9],
      reuse_study?=if args.length() == 11 { Some(args[10]) } else { None },
    )
    println(report.stringify())
    return
  }
  guard args.length() == 2 else {
    fail("usage: moon run --target native cmd/reference_train -- CONFIG.json")
  }
  let raw = @fs.read_file(args[1]).binary()
  let config : Config = @json.from_json(@json.parse(@utf8.decode(raw)))
  guard config.cycles > 0 &&
    (config.method == "model-based" || config.method == "ppo") else {
    fail("positive cycles and model-based/ppo method required")
  }
  guard !@fs.exists(config.output) else {
    fail("reference output directory already exists")
  }
  @fs.mkdir(config.output, recursive=true)
  let (actor, metadata) = @reference.load_reference_actor(
    config.actor_checkpoint,
    expected_sha256=config.actor_sha256,
  )
  let geometry = @reference.kinematics_from_spec(metadata.kinematics)
  let (manifest, archives) = @reference.load_references(config.references)
  let clips = archives.map(archive => archive.clip())
  let schedule = @reference.ReferenceSchedule::new(
    clips,
    geometry,
    config.origins,
    metadata.dt_s,
  )
  let runtime = @physics.Runtime::open(config.library, config.scene)
  let rng = @numeric.Rng::new(config.seed)
  let settings : @reference.ReferenceLearningConfig = {
    gamma: config.gamma,
    gae_lambda: config.gae_lambda,
    raw_action_std: config.raw_action_std,
    imagination_horizon: config.imagination_horizon,
    critic_updates: config.critic_updates,
    critic_batch_size: config.critic_batch_size,
    model_updates: config.model_updates,
    model_batch_size: config.model_batch_size,
    actor_steps: config.actor_steps,
    actor_batch_size: config.actor_batch_size,
    ppo_epochs: config.ppo_epochs,
    ppo_minibatch_size: config.ppo_minibatch_size,
    ppo_clip: config.ppo_clip,
    ppo_target_kl: config.ppo_target_kl,
    actor_trajectory_states: config.actor_trajectory_states,
    actor_critic_tail: config.actor_critic_tail,
    feedback_gradient: @reference.Full,
  }
  let collect = () => {
    let episodes : Array[@reference.CollectedBatch] = []
    for clip, archive in archives {
      let case = match archive.metadata {
        Object(fields) => fields["case"]
        _ => fail("reference case metadata")
      }
      let (keyframe, friction) = match case {
        Object(fields) => {
          let keyframe = match fields["keyframe"] {
            String(value) => value
            _ => fail("keyframe string")
          }
          let friction = match fields["friction"] {
            Number(value, ..) => value
            _ => fail("friction number")
          }
          (keyframe, friction)
        }
        _ => fail("case object")
      }
      for origin in config.origins {
        episodes.push(
          @reference.collect_episode(
            runtime,
            archive,
            schedule,
            actor,
            geometry,
            clip,
            origin,
            keyframe,
            friction,
            rng,
            config.raw_action_std,
            config.gamma,
          ),
        )
      }
    }
    @reference.join_batches(episodes)
  }
  let initial = collect()
  let states = @numeric.fit_normalization(
    initial.points.map(point => point.state),
    config.normalization_floor,
  )
  let actions = @numeric.fit_normalization(
    initial.actions,
    config.normalization_floor,
  )
  let contexts = @numeric.fit_normalization(
    initial.points.map(point => point.context),
    config.normalization_floor,
  )
  let model = @training.Dynamics::new(
    states,
    actions,
    contexts,
    config.model_width,
    rng,
    translation_invariant=true,
  )
  let value = @reference.ReferenceValue::new(
    actor,
    states.mean,
    states.scale,
    archives.length(),
    rng,
  )
  let actor_optimizer = @numeric.Adam::new(
    actor.parameters().length(),
    config.actor_learning_rate,
  )
  let model_optimizer = @numeric.Adam::new(
    model.network.parameters.length(),
    config.model_learning_rate,
  )
  let value_optimizer = @numeric.Adam::new(
    value.parameters().length(),
    config.critic_learning_rate,
  )
  let replay = @reference.ReferenceModelReplay::new(
    config.model_replay_windows,
    config.model_window,
  )
  let rows : Array[Json] = []
  let mut batch = initial
  for cycle in 1..<=config.cycles {
    if cycle > 1 {
      batch = collect()
    }
    let collection = config.output + "/collection-cycle-\{cycle}.json"
    let collection_hash = @reference.save_collected_batch(collection, batch)
    let advantages = if config.method == "ppo" {
      @reference.ppo_advantages(
        batch.reward,
        batch.done,
        batch.points.map(point => {
          @reference.value_at_point(value, point, schedule)
        }),
        config.gamma,
        config.gae_lambda,
      )
    } else {
      []
    }
    let value_loss = @reference.fit_value_updates(
      value, value_optimizer, batch, schedule, settings, rng,
    )
    let mut model_loss = 0.0
    let actor_update : Json = if config.method == "model-based" {
      let episodes : Array[@reference.LearningEpisode] = []
      let mut start = 0
      for length in batch.episode_lengths {
        episodes.push({
          state: batch.points[start:start + length].map(point => point.state),
          action: batch.actions[start:start + length].to_owned(),
          next_state: batch.next_states[start:start + length].to_owned(),
          context: batch.points[start].context,
        })
        start += length
      }
      replay.append(episodes)
      model_loss = @reference.fit_model_updates(
        model, model_optimizer, replay, settings, rng,
      )
      let updates = @reference.optimize_model_actor(
        model,
        actor,
        Some(value),
        actor_optimizer,
        batch,
        geometry,
        schedule,
        settings,
        rng,
      )
      {
        "model_actor_updates": updates.length(),
        "last_objective": updates[updates.length() - 1].0,
      }
    } else {
      @reference.optimize_ppo_actor(
        actor, actor_optimizer, batch, advantages, schedule, settings, rng,
      ).to_json()
    }
    let actor_path = config.output + "/actor-cycle-\{cycle}.json"
    let actor_hash = @reference.save_reference_actor(
      actor_path,
      actor,
      metadata.kinematics,
      metadata.dt_s,
      { "seed": config.seed, "cycle": cycle, "method": config.method },
      critic_status="trained",
    )
    let model_path = config.output + "/dynamics-cycle-\{cycle}.json"
    let model_hash = @artifacts.save_checkpoint(
      model_path,
      model.checkpoint({
        "cycle": cycle,
        "collection": collection,
        "collection_sha256": collection_hash,
      }),
    )
    let value_path = config.output + "/value-cycle-\{cycle}.json"
    let value_hash = @reference.save_reference_value(value_path, value, {
      "cycle": cycle,
      "collection_sha256": collection_hash,
    })
    let state_path = config.output + "/training-state-cycle-\{cycle}.json"
    let state : @reference.ReferenceTrainingState = {
      actor,
      value,
      model: model.checkpoint({ "cycle": cycle }),
      replay,
      actor_optimizer,
      value_optimizer,
      model_optimizer,
      rng_state: rng.state(),
      cycle,
      config: @json.parse(@utf8.decode(raw)),
      provenance: {
        "source_actor_sha256": config.actor_sha256,
        "reference_manifest": manifest,
      },
    }
    let state_hash = @reference.save_training_state(state_path, state)
    let row : Json = {
      "cycle": cycle,
      "collection": collection,
      "collection_sha256": collection_hash,
      "actor": actor_path,
      "actor_sha256": actor_hash,
      "model": model_path,
      "model_sha256": model_hash,
      "value": value_path,
      "value_sha256": value_hash,
      "training_state": state_path,
      "training_state_sha256": state_hash,
      "value_loss": value_loss,
      "model_loss": model_loss,
      "actor_update": actor_update,
      "physical_transitions": batch.points.length(),
    }
    rows.push(row)
    println(row.stringify())
  }
  let report : Json = {
    "format": "moonrobo.g1-reference-learning.moonbit.v1",
    "source_config_sha256": @artifacts.sha256(raw),
    "reference_manifest": manifest,
    "rng": "MoonBit xorshift32; not Torch seed-equivalent",
    "runs": rows,
    "physical_execution_allowed": false,
    "release_qualified": false,
    "post_training_evaluated": false,
    "native_state_saved": true,
    "resume_cli_available": false,
  }
  @fs.write_file(
    config.output + "/report.json",
    @utf8.encode(report.stringify(indent=2)),
    create_mode=CreateOrTruncate,
  )
}
