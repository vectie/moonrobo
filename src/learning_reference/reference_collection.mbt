///|
pub(all) struct CollectedBatch {
  points : Array[LearningPoint]
  actions : Array[Array[Double]]
  next_states : Array[Array[Double]]
  latent : Array[Array[Double]]
  old_mean : Array[Array[Double]]
  reward : Array[Double]
  done : Array[Bool]
  returns : Array[Double]
  episode_lengths : Array[Int32]
} derive(Debug, ToJson, FromJson)

///|
pub fn reward_from_geometry(
  geometry : @balance.Kinematics,
  state : Array[Double],
  action : Array[Double],
  previous : Array[Double],
  positions : Array[Array[Double]],
  quaternion : Array[Double],
  joints : Array[Double],
  dt : Double,
) -> RewardResult {
  let (p, r) = geometry.body_poses(state[7:36].to_owned())
  let rotations = r.map(rotation => {
    Array::makei(3, i => rotation[i * 3:i * 3 + 3].to_owned())
  })
  let mass = geometry.bodies.fold(init=0.0, (sum, body) => sum + body.mass)
  reference_reward(
    state,
    action,
    previous,
    positions,
    quaternion,
    joints,
    p,
    rotations,
    geometry.bodies.map(body => body.com_position),
    geometry.bodies.map(body => body.mass / mass),
    geometry.feet.map(site => site.body),
    geometry.feet.map(site => site.position),
    dt~,
  )
}

///|
pub fn collect_episode(
  runtime : @physics.Runtime,
  archive : ReferenceArchive,
  schedule : ReferenceSchedule,
  actor : ReferenceActor,
  geometry : @balance.Kinematics,
  clip : Int32,
  origin : Int32,
  keyframe : String,
  friction : Double,
  rng : @numeric.Rng,
  raw_action_std : Double,
  gamma : Double,
  maximum_action_alignment_error~ : Double = 0.00008,
  maximum_feature_alignment_error~ : Double = 0.00002,
) -> CollectedBatch raise {
  guard origin >= 0 && origin < schedule.length && actor.nu == geometry.nu else {
    fail("invalid reference episode origin or shape")
  }
  let integration = archive.matrix("integration")
  let observations = archive.matrix("observation")
  let controls = archive.matrix("source_setpoint")
  runtime.reset(keyframe, friction)
  runtime.set_integration(integration[origin])
  let substeps = runtime.control_substeps(schedule.dt)
  let history = ReferenceHistory::new(actor.history_length)
  let actual = @balance.BalanceHistory::full_memory(geometry, schedule.dt)
  let planned = @balance.BalanceHistory::full_memory(geometry, schedule.dt)
  let points : Array[LearningPoint] = []
  let actions : Array[Array[Double]] = []
  let next_states : Array[Array[Double]] = []
  let latent : Array[Array[Double]] = []
  let old_mean : Array[Array[Double]] = []
  let reward : Array[Double] = []
  let done : Array[Bool] = []
  let mut previous = if origin > 0 {
    controls[origin - 1].copy()
  } else {
    observations[0][observations[0].length() - actor.nu:].to_owned()
  }
  for phase in origin..<schedule.length {
    let observation = if phase == origin {
      let obs = observations[origin].copy()
      for i in 0..<actor.nu {
        obs[obs.length() - actor.nu + i] = previous[i]
      }
      obs
    } else {
      runtime.observation(previous)
    }
    let state = runtime.state()
    let h = history.push(observation)
    let command = schedule.command(clip, phase, actor.future_length)
    let actual_features = actual.observe(observation)
    let reference_features = planned.observe(
      reference_observation(command.current, nu=actor.nu),
    )
    let mean = actor.latent_mean(
      h,
      command.current,
      command.future,
      command.valid,
    )
    let sampled = mean.map(x => x + raw_action_std * rng.normal())
    let requested = actor.action_from_latent(
      sampled,
      h,
      command.current,
      actual_features,
      reference_features,
    )
    let action = runtime.clip_control(requested)
    for i, x in requested {
      guard (action[i] - x).abs() <= maximum_action_alignment_error else {
        fail("collected latent and applied control disagree")
      }
    }
    let expected_features = schedule.features(clip, origin, phase)
    for i, x in reference_features {
      guard (expected_features[i] - x).abs() <= maximum_feature_alignment_error else {
        fail("precomputed planned observer differs from physical runner")
      }
    }
    let next_state = runtime.step(action, substeps)
    let reference = schedule.clips[clip]
    let result = reward_from_geometry(
      geometry,
      next_state,
      action,
      previous,
      reference.positions[phase + 1],
      reference.quaternions[phase + 1],
      reference.goals[phase + 1][:actor.nu].to_owned(),
      schedule.dt,
    )
    guard result.fallen ==
      (runtime.root_height() < 0.35 || runtime.upright() < 0.5) else {
      fail("shared fall test differs from physical harness")
    }
    points.push({
      state,
      history: h,
      actual_features,
      reference_features,
      context: [friction, 1.0],
      clip,
      step: phase,
      origin,
    })
    actions.push(action)
    next_states.push(next_state)
    latent.push(sampled)
    old_mean.push(mean)
    reward.push(result.reward)
    done.push(result.fallen || phase + 1 == schedule.length)
    previous = action
    if result.fallen {
      break
    }
  }
  {
    points,
    actions,
    next_states,
    latent,
    old_mean,
    reward,
    done,
    returns: finite_returns(reward, gamma),
    episode_lengths: [points.length()],
  }
}

///|
pub fn join_batches(batches : Array[CollectedBatch]) -> CollectedBatch {
  let result : CollectedBatch = {
    points: [],
    actions: [],
    next_states: [],
    latent: [],
    old_mean: [],
    reward: [],
    done: [],
    returns: [],
    episode_lengths: [],
  }
  for batch in batches {
    result.points.append(batch.points)
    result.actions.append(batch.actions)
    result.next_states.append(batch.next_states)
    result.latent.append(batch.latent)
    result.old_mean.append(batch.old_mean)
    result.reward.append(batch.reward)
    result.done.append(batch.done)
    result.returns.append(batch.returns)
    result.episode_lengths.append(batch.episode_lengths)
  }
  result
}

///|
pub async fn save_collected_batch(
  path : String,
  batch : CollectedBatch,
) -> String {
  let checkpoint = @artifacts.Checkpoint::new(
    "moonrobo.g1-reference-collection.moonbit.v1",
    { "batch": batch.to_json(), "physical_execution_allowed": false },
  )
  checkpoint.put("reward", [batch.reward.length()], batch.reward)
  @artifacts.save_checkpoint(path, checkpoint)
}

///|
pub async fn restore_collected_batch(
  path : String,
  sha256 : String,
) -> CollectedBatch {
  let checkpoint = @artifacts.load_checkpoint(
    path,
    "moonrobo.g1-reference-collection.moonbit.v1",
    expected_sha256=sha256,
  )
  let batch : CollectedBatch = @json.from_json(
    json_field(checkpoint.metadata, "batch"),
  )
  guard batch.reward == checkpoint.tensor("reward").values &&
    batch.points.length() == batch.reward.length() else {
    fail("collection metadata and tensors disagree")
  }
  batch
}

///|
/// Original Python numeric archives can be reused directly; causal history is
/// reconstructed independently for every episode, never across reset boundaries.
pub async fn restore_python_collection(
  path : String,
  sha256 : String,
  clip : Int32,
  origin : Int32,
  context : Array[Double],
  actor : ReferenceActor,
  schedule : ReferenceSchedule,
  gamma : Double,
) -> CollectedBatch {
  let bytes = @fs.read_file(path).binary()
  guard @artifacts.sha256(bytes) == sha256 else {
    fail("reused physical archive changed")
  }
  let arrays = @artifacts.decode_npz(bytes)
  let archive : ReferenceArchive = {
    metadata: Json::null(),
    layout: Json::null(),
    arrays,
  }
  let state = archive.matrix("state")
  let obs = archive.matrix("observation")
  let actual = archive.matrix("actual_features")
  let planned = archive.matrix("reference_features")
  let history = ReferenceHistory::new(actor.history_length)
  let points = state.mapi((i, s) => {
    (
      {
        state: s,
        history: history.push(obs[i]),
        actual_features: actual[i],
        reference_features: planned[i],
        context,
        clip,
        step: origin + i,
        origin,
      } : LearningPoint)
  })
  let reward = arrays["reward"].values
  guard !points.is_empty() && origin + points.length() <= schedule.length else {
    fail("invalid collected episode length")
  }
  let done = Array::make(points.length(), false)
  done[done.length() - 1] = true
  {
    points,
    actions: archive.matrix("applied_action"),
    next_states: archive.matrix("next_state"),
    latent: archive.matrix("latent"),
    old_mean: archive.matrix("old_mean"),
    reward,
    done,
    returns: finite_returns(reward, gamma),
    episode_lengths: [points.length()],
  }
}
