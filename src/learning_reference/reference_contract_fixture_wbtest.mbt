///|
/// These fixtures deliberately require the real library and original scene.
/// Missing dependencies fail the requested test instead of reporting a skip/pass.
struct ContractFixture {
  runtime : @physics.Runtime
  geometry : @balance.Kinematics
  archive : ReferenceArchive
  reference : @balance_native.NativeReference
  episode : @physics.Episode
  schedule : ReferenceSchedule
  actor : ReferenceActor
  points : Array[LearningPoint]
}

///|
fn contract_close(
  actual : Array[Double],
  expected : Array[Double],
  atol~ : Double = 1.0e-10,
  rtol~ : Double = 0.0,
) -> Unit raise {
  assert_eq(actual.length(), expected.length())
  for i, x in actual {
    assert_true(
      (x - expected[i]).abs() <= atol + rtol * expected[i].abs(),
      msg="element \{i}: \{x} versus \{expected[i]}",
    )
  }
}

///|
fn contract_fixture(
  seed~ : UInt32 = 77U,
  motion~ : String = "stand",
  seconds~ : Double = 0.4,
) -> ContractFixture raise {
  let library = @env.get_env_var("MOONROBO_MUJOCO_LIBRARY").unwrap_or("")
  guard !library.is_empty() else {
    fail(
      "real G1 fixture requires MOONROBO_MUJOCO_LIBRARY; no simulation test was skipped",
    )
  }
  let scene = @env.get_env_var("MOONROBO_G1_SCENE").unwrap_or(
    "target/mujoco_menagerie/unitree_g1/scene_mjx.xml",
  )
  let runtime = @physics.Runtime::open(library, scene)
  let geometry = @balance_native.make_spec(runtime)
  let rng = @numeric.Rng::new(seed)
  let frames : Array[@balance_native.ReferenceFrame] = []
  let capture = (time : Double) => {
    let frame = try! @balance_native.capture_frame(runtime, time)
    frames.push({
      ..frame,
      body_rotation: runtime.body_rotations(include_world=false),
    })
  }
  let case : @physics.Case = {
    id: "stand",
    family: "reference-contract",
    split: "train",
    keyframe: "home",
    motion,
    friction: 1.0,
  }
  let case_fields = json_fields(case.to_json())
  case_fields["goal_offset_rad"] = {
    "lower": 0.02,
    "waist": 0.06,
    "upper": 0.12,
  }
  let (offset, schedule) = @balance_native.sample_reference(
    runtime,
    case_fields.to_json(),
    seed.to_int(),
  )
  let (episode, _) = runtime.rollout(
    case,
    seed.to_int(),
    "position",
    seconds,
    0.02,
    () => rng.normal(),
    offset?,
    schedule?,
    trace=(i, _, _) => capture(i.to_double() * 0.02),
  )
  capture(episode.steps.length().to_double() * 0.02)
  let controls = episode.steps.map(s => s.applied_action)
  let observations = episode.steps.map(s => s.observation)
  let reference = @balance_native.NativeReference::new(
    runtime, frames, controls, observations, 0.02,
  )
  let bodies = geometry.bodies.length()
  let flatten = (rows : Array[Array[Double]]) => {
    rows.fold(init=[], (a, b) => {
      a.append(b)
      a
    })
  }
  let arrays = {
    "state": matrix_tensor(frames.map(f => f.state)),
    "integration": matrix_tensor(frames.map(f => f.integration)),
    "observation": matrix_tensor(observations),
    "source_setpoint": matrix_tensor(controls),
    "body_position": archive_tensor(
      [frames.length(), bodies, 3],
      flatten(frames.map(f => flatten(f.body_position))),
    ),
    "body_rotation": archive_tensor(
      [frames.length(), bodies, 3, 3],
      flatten(frames.map(f => flatten(f.body_rotation))),
    ),
    "body_quaternion": archive_tensor(
      [frames.length(), bodies, 4],
      flatten(frames.map(f => flatten(f.body_quaternion))),
    ),
    "contacts": archive_tensor(
      [frames.length()],
      frames.map(f => f.contacts.to_double()),
    ),
    "time_s": archive_tensor([frames.length()], frames.map(f => f.time)),
  }
  let archive : ReferenceArchive = {
    metadata: {
      "id": "stand",
      "source_family": "reference-contract",
      "sha256": "fixture",
      "split": "train",
      "case": case.to_json(),
      "source_reset_seed": seed.to_int(),
    },
    layout: {
      "nq": reference.nq,
      "q_indices": reference.q_indices,
      "v_indices": reference.v_indices,
      "root_body_index": reference.root_index,
      "dt_s": 0.02,
    },
    arrays,
  }
  let schedule = ReferenceSchedule::new(
    [archive.clip()],
    geometry,
    [0, 3, 4],
    0.02,
  )
  let (lower, upper) = runtime.control_bounds()
  let actor = ReferenceActor::new(
    reference.reference.goals[0].length(),
    29,
    lower,
    upper,
    Array::makei(4, _ => Array::make(5, 0.0)),
    [4, 5, 10, 11],
    rng,
    history_length=3,
    future_length=2,
    width=16,
    latent_dim=8,
  )
  let points = [0, 3].map(origin => {
    let actual_features = geometry.from_observation(observations[origin])
    actual_features.append([0.0, 0.0, 0.0])
    (
      {
        state: frames[origin].state,
        history: Array::makei(3, _ => observations[origin].copy()),
        actual_features,
        reference_features: schedule.features(0, origin, origin),
        context: [1.0, 1.0],
        clip: 0,
        step: origin,
        origin,
      } : LearningPoint)
  })
  { runtime, geometry, archive, reference, episode, schedule, actor, points, }
}

///|
fn contract_model(rng : @numeric.Rng) -> @training.Dynamics {
  let norm = n => {
    (
      { mean: Array::make(n, 0.0), scale: Array::make(n, 1.0), } :
      @numeric.Normalization)
  }
  let model = @training.Dynamics::new(norm(71), norm(29), norm(2), 16, rng)
  let last = model.network.parameters.length() - 71 * 17
  for i in last..<(model.network.parameters.length() - 71) {
    model.network.parameters[i] = rng.normal() * 0.0001
  }
  model
}

///|
fn contract_config() -> ReferenceLearningConfig {
  {
    gamma: 0.99,
    gae_lambda: 0.95,
    raw_action_std: 0.03,
    imagination_horizon: 4,
    critic_updates: 1,
    critic_batch_size: 2,
    model_updates: 3,
    model_batch_size: 4,
    actor_steps: 2,
    actor_batch_size: 2,
    ppo_epochs: 1,
    ppo_minibatch_size: 2,
    ppo_clip: 0.2,
    ppo_target_kl: 0.01,
    actor_trajectory_states: false,
    actor_critic_tail: false,
    feedback_gradient: Full,
  }
}

///|
fn contract_batch(f : ContractFixture) -> CollectedBatch {
  {
    points: f.points,
    actions: Array::makei(2, _ => Array::make(29, 0.0)),
    next_states: f.points.map(p => p.state),
    latent: Array::makei(2, _ => Array::make(29, 0.0)),
    old_mean: Array::makei(2, _ => Array::make(29, 0.0)),
    reward: [0.0, 0.0],
    done: [true, true],
    returns: [0.0, 0.0],
    episode_lengths: [1, 1],
  }
}

///|
fn contract_path(label : String) -> String {
  "/tmp/moonrobo-reference-contract-" +
  label +
  "-" +
  @env.now().to_string() +
  ".json"
}

///|
fn contract_spec(f : ContractFixture) -> Json {
  {
    "format": "moonrobo.balance-kinematics.v1",
    "joint_names": f.runtime.joint_names(),
    "bodies": f.geometry.bodies,
    "feet": f.geometry.feet,
  }
}
