///|
pub fn collect_episode_with_trial(
  runtime : @physics.Runtime,
  archive : ReferenceArchive,
  schedule : ReferenceSchedule,
  actor : ReferenceActor,
  geometry : @balance.Kinematics,
  clip : Int32,
  origin : Int32,
  rng : @numeric.Rng,
  raw_action_std : Double,
  gamma : Double,
  maximum_action_alignment_error : Double,
  maximum_feature_alignment_error : Double,
) -> (CollectedBatch, Json, Double, Double) raise {
  let native = archive.native_reference(runtime, schedule.dt)
  let case : @physics.Case = @json.from_json(
    json_field(archive.metadata, "case"),
  )
  let history = ReferenceHistory::new(actor.history_length)
  let actual = @balance.BalanceHistory::full_memory(geometry, schedule.dt)
  let planned = @balance.BalanceHistory::full_memory(geometry, schedule.dt)
  let histories : Array[Array[Array[Double]]] = []
  let actual_features : Array[Array[Double]] = []
  let reference_features : Array[Array[Double]] = []
  let means : Array[Array[Double]] = []
  let latents : Array[Array[Double]] = []
  let (episode, trial) = @balance_native.replay_reference(
    runtime,
    native,
    case,
    origin,
    "policy",
    preview_length=actor.future_length,
    policy=(obs, current, future, valid) => {
      let h = history.push(obs)
      let a = actual.observe(obs)
      let r = planned.observe(reference_observation(current, nu=actor.nu))
      let mean = actor.latent_mean(h, current, future, valid)
      let latent = mean.map(x => x + raw_action_std * rng.normal())
      histories.push(h)
      actual_features.push(a)
      reference_features.push(r)
      means.push(mean)
      latents.push(latent)
      actor.action_from_latent(latent, h, current, a, r)
    },
  )
  let points : Array[LearningPoint] = []
  let rewards : Array[Double] = []
  let mut action_alignment = 0.0
  let mut feature_alignment = 0.0
  for i, step in episode.steps {
    let phase = origin + i
    let reference = schedule.clips[clip]
    let previous = step.observation[step.observation.length() - actor.nu:].to_owned()
    let reward = reward_from_geometry(
      geometry,
      step.next_state,
      step.applied_action,
      previous,
      reference.positions[phase + 1],
      reference.quaternions[phase + 1],
      reference.goals[phase + 1][:actor.nu].to_owned(),
      schedule.dt,
    )
    guard reward.fallen == step.terminated else {
      fail("shared fall test differs from physical harness")
    }
    let applied = actor.action_from_latent(
      latents[i],
      histories[i],
      reference.goals[phase],
      actual_features[i],
      reference_features[i],
    )
    for j, x in applied {
      action_alignment = action_alignment.max(
        (x - step.applied_action[j]).abs(),
      )
      guard action_alignment <= maximum_action_alignment_error else {
        fail("collected latent and applied control disagree")
      }
    }
    let planned = schedule.features(clip, origin, phase)
    for j, x in planned {
      feature_alignment = feature_alignment.max(
        (x - reference_features[i][j]).abs(),
      )
      guard feature_alignment <= maximum_feature_alignment_error else {
        fail("precomputed planned observer differs from physical runner")
      }
    }
    points.push({
      state: step.state,
      history: histories[i],
      actual_features: actual_features[i],
      reference_features: reference_features[i],
      context: episode.context,
      clip,
      step: phase,
      origin,
    })
    rewards.push(reward.reward)
  }
  let n = points.length()
  let done = Array::make(n, false)
  done[n - 1] = true
  (
    {
      points,
      actions: episode.steps.map(step => step.applied_action),
      next_states: episode.steps.map(step => step.next_state),
      latent: latents,
      old_mean: means,
      reward: rewards,
      done,
      returns: finite_returns(rewards, gamma),
      episode_lengths: [n],
    },
    trial,
    action_alignment,
    feature_alignment,
  )
}

///|
pub fn collected_npz(
  batch : CollectedBatch,
) -> Map[String, @artifacts.NumericArray] {
  let n = batch.points.length()
  let terminated = batch.next_states.map(state => {
    let r = quaternion_matrix(state[3:7].to_owned())
    state[2] < 0.35 || r[2][2] < 0.5
  })
  {
    "state": matrix_tensor(batch.points.map(point => point.state)),
    "next_state": matrix_tensor(batch.next_states),
    "observation": matrix_tensor(
      batch.points.map(point => point.history[point.history.length() - 1]),
    ),
    "applied_action": matrix_tensor(batch.actions),
    "latent": matrix_tensor(batch.latent),
    "old_mean": matrix_tensor(batch.old_mean),
    "actual_features": matrix_tensor(
      batch.points.map(point => point.actual_features),
    ),
    "reference_features": matrix_tensor(
      batch.points.map(point => point.reference_features),
    ),
    "reward": archive_tensor([n], batch.reward),
    "terminated": archive_tensor(
      [n],
      terminated.map(value => if value { 1.0 } else { 0.0 }),
    ),
    "truncated": archive_tensor(
      [n],
      Array::makei(n, i => if i == n - 1 && !terminated[i] { 1.0 } else { 0.0 }),
    ),
  }
}

///|
pub(all) struct PhysicalGroup {
  batch : CollectedBatch
  records : Array[Json]
  trials : Array[Json]
  seconds : Double
}

///|
pub async fn physical_group(
  runtime : @physics.Runtime,
  references : Array[ReferenceArchive],
  schedule : ReferenceSchedule,
  actor : ReferenceActor,
  geometry : @balance.Kinematics,
  config : Json,
  seed : Int32,
  cycle : Int32,
  role : String,
  folder : String,
  root : String,
  behavior : Json,
  origins : Array[Int32],
  clips : Array[Int32],
  tag : String,
) -> PhysicalGroup {
  let started = @async.now()
  @fs.mkdir(folder + "/physics/" + role, recursive=true)
  let batches : Array[CollectedBatch] = []
  let records : Array[Json] = []
  let trials : Array[Json] = []
  let std = if ["training", "common-first-collection", "model-diagnostic"].contains(
      role,
    ) {
    json_number(json_field(config, "raw_action_std"))
  } else {
    0.0
  }
  let stride = match config {
    Object(fields) =>
      match fields.get("noise_seed_origin_stride") {
        Some(value) => json_integer(value)
        None => 0
      }
    _ => fail("learning config")
  }
  for clip in clips {
    for origin in origins {
      let seed_value = json_integer(json_field(config, "noise_seed_base")) +
        seed * 1000000 +
        cycle * 1000 +
        clip +
        origin * stride +
        (if role == "model-diagnostic" { 50000 } else { 0 })
      let rng = @numeric.Rng::new(seed_value.reinterpret_as_uint())
      let (batch, trial, action_error, feature_error) = collect_episode_with_trial(
        runtime,
        references[clip],
        schedule,
        actor,
        geometry,
        clip,
        origin,
        rng,
        std,
        json_number(json_field(config, "gamma")),
        json_number(json_field(config, "maximum_action_alignment_error_rad")),
        json_number(json_field(config, "maximum_feature_alignment_error")),
      )
      let id = json_text(json_field(trial, "episode_id")) +
        "-\{tag}-\{role}-seed-\{seed}-cycle-\{cycle}"
      let trial_fields = json_fields(trial)
      trial_fields["episode_id"] = id.to_json()
      let path = folder + "/physics/" + role + "/" + id + ".npz"
      let hash = @artifacts.save_npz(path, collected_npz(batch))
      let relative = if path.has_prefix(root + "/") {
        path[root.length() + 1:].to_owned()
      } else {
        path
      }
      let archive = references[clip]
      records.push({
        "file": relative,
        "sha256": hash,
        "episode_id": id,
        "reference_id": json_field(archive.metadata, "id"),
        "reference_sha256": json_field(archive.metadata, "sha256"),
        "source_family": json_field(archive.metadata, "source_family"),
        "split": "train",
        "context": batch.points[0].context,
        "clip_index": clip,
        "origin_step": origin,
        "seed": seed,
        "cycle": cycle,
        "role": role,
        "steps": batch.points.length(),
        "behavior": behavior,
        "action_std": std,
        "storage_dtype": "float64",
        "rng_backend": "native-xorshift32",
        "maximum_action_alignment_error": action_error,
        "maximum_reference_feature_error": feature_error,
      })
      batches.push(batch)
      trials.push(trial_fields.to_json())
    }
  }
  {
    batch: join_batches(batches),
    records,
    trials,
    seconds: (@async.now() - started).to_double() / 1000.0,
  }
}
