///|
/// Deferred native fixtures require the real MuJoCo library and G1 model.
struct TestFixture {
  runtime : @physics.Runtime
  geometry : @balance.Kinematics
  snapshot : Snapshot
  target : Targets
  actor : @ref.ReferenceActor
  model : @training.Dynamics
  schedule : @ref.ReferenceSchedule
  inputs : FeedbackInputs
}

///|
fn test_fixture() -> TestFixture raise {
  guard @env.get_env_var("MOONROBO_MUJOCO_LIBRARY") is Some(library) else {
    fail("deferred native tests require MOONROBO_MUJOCO_LIBRARY")
  }
  let scene = @env.get_env_var("MOONROBO_MUJOCO_SCENE").unwrap_or(
    "target/mujoco_menagerie/unitree_g1/scene_mjx.xml",
  )
  let runtime = @physics.Runtime::open(library, scene)
  let geometry = @bphysics.make_spec(runtime)
  let frames : Array[@bphysics.ReferenceFrame] = []
  let rng = @numeric.Rng::new(78U)
  let case : @physics.Case = {
    id: "stand",
    family: "stand",
    split: "train",
    keyframe: "home",
    motion: "stand",
    friction: 1.0,
  }
  let (episode, _) = runtime.rollout(
    case,
    77,
    "position",
    0.4,
    0.02,
    () => rng.normal(),
    trace=(i, _, _) => {
      frames.push(try! @bphysics.capture_frame(runtime, i.to_double() * 0.02))
    },
  )
  frames.push(@bphysics.capture_frame(runtime, 0.4))
  let reference = @bphysics.NativeReference::new(
    runtime,
    frames,
    episode.steps.map(s => s.applied_action),
    episode.steps.map(s => s.observation),
    0.02,
  )
  let goals = reference.reference.goals
  let snapshot : Snapshot = {
    state: frames[0].state,
    integration: frames[0].integration,
    observation: episode.steps[0].observation,
    actions: Array::makei(8, i => episode.steps[i].applied_action),
    context: [1.0, 1.0],
  }
  let target : Targets = {
    positions: Array::makei(8, i => {
      frames[i + 1].body_position.map(row => {
        row.map(v => v.to_float().to_double())
      })
    }),
    quaternions: Array::makei(8, i => {
      Array::makei(4, j => frames[i + 1].state[3 + j].to_float().to_double())
    }),
    joints: Array::makei(8, i => {
      Array::makei(29, j => goals[i + 1][j].to_float().to_double())
    }),
  }
  let clip : @ref.ReferenceClip = {
    goals,
    positions: frames.map(f => f.body_position),
    quaternions: frames.map(f => Array::makei(4, j => f.state[3 + j])),
  }
  let schedule = @ref.ReferenceSchedule::new([clip], geometry, [0], 0.02)
  let (lower, upper) = runtime.control_bounds()
  let actor = @ref.ReferenceActor::new(
    goals[0].length(),
    29,
    lower,
    upper,
    Array::makei(4, _ => Array::make(5, 0.0)),
    [4, 5, 10, 11],
    @numeric.Rng::new(179U),
    history_length=3,
    future_length=2,
    width=16,
    latent_dim=8,
  )
  let stats = (n : Int32) => {
    (
      { mean: Array::make(n, 0.0), scale: Array::make(n, 1.0), } :
      @numeric.Normalization)
  }
  let model = @training.Dynamics::new(
    stats(71),
    stats(29),
    stats(2),
    16,
    @numeric.Rng::new(179U),
    translation_invariant=true,
  )
  let draw = @numeric.Rng::new(181U)
  let offset = 102 * 16 + 16 + (16 * 16 + 16)
  for i in offset..<(offset + 71 * 16) {
    model.network.parameters[i] = draw.normal() * 0.0001
  }
  let history = Array::makei(3, _ => snapshot.observation.copy())
  let features = @balance.sequence_features(
      geometry,
      [snapshot.observation],
      0.02,
      None,
      @balance.GravityGyro,
    )[0]
  let inputs : FeedbackInputs = {
    snapshot: {
      ..snapshot,
      actions: Array::makei(4, i => snapshot.actions[i]),
    },
    history,
    features,
    planned: schedule.features(0, 0, 0),
    clip: 0,
    phase: 0,
  }
  { runtime, geometry, snapshot, target, actor, model, schedule, inputs, }
}

///|
test "first action changes alone and matches real runtime clipping" {
  let f = test_fixture()
  let original = f.snapshot.actions.map(a => a.copy())
  let (lower, upper) = f.runtime.control_bounds()
  let result = @ref.first_action_tape(
    original,
    Array::make(29, 1.0),
    100,
    lower,
    upper,
  )
  assert_eq(result[0], f.runtime.clip_control(original[0].map(v => v + 100)))
  for i in 1..<original.length() {
    assert_eq(result[i], original[i])
  }
  assert_eq(original, f.snapshot.actions)
}

///|
test "first action gradient direction excludes saturated coordinates" {
  let action = Array::make(29, 0.0)
  action[0] = -1
  action[1] = 0.999
  let lower = Array::make(29, -1.0)
  let upper = Array::make(29, 1.0)
  let feasible = @ref.control_direction(
    [Array::make(29, 1.0)],
    [[action]],
    lower,
    upper,
    0.001,
  )
  assert_eq(feasible.interior_coordinates, 27)
  assert_eq(feasible.direction[0][0], 0)
  assert_eq(feasible.direction[0][1], 0)
  let mut square = 0.0
  for v in feasible.direction[0] {
    square += v * v
  }
  assert_true((square / 29 - 1).abs() < 0.000000000001)
  for amplitude in [-0.001, -0.0001, 0.0001, 0.001] {
    let result = @ref.first_action_tape(
      [action],
      feasible.direction[0],
      amplitude,
      lower,
      upper,
    )
    for i in 0..<29 {
      assert_eq(result[0][i], action[i] + amplitude * feasible.direction[0][i])
    }
  }
}

///|
test "full solver snapshot restores identical physical branch after intervention" {
  let f = test_fixture()
  let baseline = physics_branch(
    f.runtime,
    f.snapshot,
    f.snapshot.actions,
    f.target,
    f.geometry,
    0.02,
  )
  let (lower, upper) = f.runtime.control_bounds()
  let altered = @ref.first_action_tape(
    f.snapshot.actions,
    Array::make(29, 1.0),
    0.001,
    lower,
    upper,
  )
  ignore(
    physics_branch(f.runtime, f.snapshot, altered, f.target, f.geometry, 0.02),
  )
  let repeated = physics_branch(
    f.runtime,
    f.snapshot,
    f.snapshot.actions,
    f.target,
    f.geometry,
    0.02,
  )
  for key, a in baseline.arrays() {
    assert_eq(a.values, repeated.arrays()[key].values)
  }
  assert_true(baseline.truncated[baseline.truncated.length() - 1])
  assert_false(baseline.terminated.any(v => v))
}

///|
test "first action analytic gradient matches model finite difference" {
  let f = test_fixture()
  let first = f.snapshot.actions[0]
  let (_, gradient) = first_objective(
    f.model,
    f.geometry,
    f.snapshot,
    f.target,
    8,
    first,
    0.99,
    0.02,
  )
  let direction = Array::makei(29, i => -1.0 + 2 * i.to_double() / 28)
  let epsilon = 0.000001
  let plus = first_objective(
      f.model,
      f.geometry,
      f.snapshot,
      f.target,
      8,
      Array::makei(29, i => first[i] + epsilon * direction[i]),
      0.99,
      0.02,
    ).0
  let minus = first_objective(
      f.model,
      f.geometry,
      f.snapshot,
      f.target,
      8,
      Array::makei(29, i => first[i] - epsilon * direction[i]),
      0.99,
      0.02,
    ).0
  let mut analytic = 0.0
  let mut norm = 0.0
  for i, g in gradient {
    assert_true(@numeric.finite(g))
    analytic += g * direction[i]
    norm += g * g
  }
  assert_true(norm > 0)
  assert_true((analytic - (plus - minus) / (2 * epsilon)).abs() < 0.000001)
}

///|
test "zero feedback perturbation matches training imagination" {
  let f = test_fixture()
  let (lower, upper) = f.runtime.control_bounds()
  let zero = Array::makei(4, _ => Array::make(29, 0.0))
  let actual = model_response(
      f.model,
      f.actor,
      f.geometry,
      f.schedule,
      f.inputs,
      f.target,
      zero,
      "feedback",
      lower,
      upper,
      0.99,
      0.02,
    ).objective
  let point : @ref.LearningPoint = {
    state: f.snapshot.state,
    history: f.inputs.history,
    actual_features: f.inputs.features,
    reference_features: f.inputs.planned,
    context: [1.0, 1.0],
    clip: 0,
    step: 0,
    origin: 0,
  }
  let tape = @numeric.Tape::new()
  let expected = @ref.imagined_objective(
      tape,
      f.model,
      f.actor,
      tape.vector(f.actor.parameters()),
      None,
      [point],
      f.geometry,
      f.schedule,
      4,
      0.99,
      feedback_gradient=@ref.Full,
      critic_tail=false,
    ).0.value
  assert_true(
    (actual - expected).abs() <= 0.00000011920928955078125 * expected.abs(),
  )
}

///|
test "complete tape analytic gradients match finite difference in both modes" {
  let f = test_fixture()
  let (lower, upper) = f.runtime.control_bounds()
  let zero = Array::makei(4, _ => Array::make(29, 0.0))
  let epsilon = 0.000001
  let direction = Array::makei(4, t => {
    Array::makei(29, i => -1.0 + 2 * (t * 29 + i).to_double() / 115)
  })
  for mode in ["open-tape", "feedback"] {
    let result = model_response(
      f.model,
      f.actor,
      f.geometry,
      f.schedule,
      f.inputs,
      f.target,
      zero,
      mode,
      lower,
      upper,
      0.99,
      0.02,
    )
    let plus = model_response(
        f.model,
        f.actor,
        f.geometry,
        f.schedule,
        f.inputs,
        f.target,
        direction.map(row => row.map(v => v * epsilon)),
        mode,
        lower,
        upper,
        0.99,
        0.02,
      ).objective
    let minus = model_response(
        f.model,
        f.actor,
        f.geometry,
        f.schedule,
        f.inputs,
        f.target,
        direction.map(row => row.map(v => -v * epsilon)),
        mode,
        lower,
        upper,
        0.99,
        0.02,
      ).objective
    let mut analytic = 0.0
    let mut later = 0.0
    for t, row in result.gradient {
      for i, g in row {
        assert_true(@numeric.finite(g))
        analytic += g * direction[t][i]
        if t > 0 {
          later += g.abs()
        }
      }
    }
    assert_true(later > 0)
    assert_true((analytic - (plus - minus) / (2 * epsilon)).abs() < 0.000001)
  }
}

///|
test "common feasible mask intersects all baselines over whole tape" {
  let first = Array::makei(2, _ => Array::make(29, 0.0))
  let second = first.map(row => row.copy())
  first[0][0] = 1
  second[1][1] = -0.999
  let lower = Array::make(29, -1.0)
  let upper = Array::make(29, 1.0)
  let result = @ref.control_direction(
    Array::makei(2, _ => Array::make(29, 1.0)),
    [first, second],
    lower,
    upper,
    0.001,
  )
  assert_eq(result.interior_coordinates, 56)
  assert_eq(result.direction[0][0], 0)
  assert_eq(result.direction[1][1], 0)
  let mut square = 0.0
  for row in result.direction {
    for v in row {
      square += v * v
    }
  }
  assert_true((square / 58 - 1).abs() < 0.000000000001)
  for base in [first, second] {
    for amplitude in [-0.001, 0.001] {
      for t, row in base {
        for i, v in row {
          let target = v + amplitude * result.direction[t][i]
          assert_true(target >= lower[i] && target <= upper[i])
        }
      }
    }
  }
}

///|
test "feedback branch restores controller memory and solver after intervention" {
  let f = test_fixture()
  let zero = Array::makei(4, _ => Array::make(29, 0.0))
  let base = feedback_physics(
    f.runtime,
    f.actor,
    f.geometry,
    f.schedule,
    f.inputs,
    f.target,
    zero,
    0.02,
  )
  ignore(
    feedback_physics(
      f.runtime,
      f.actor,
      f.geometry,
      f.schedule,
      f.inputs,
      f.target,
      zero.map(row => row.map(_ => 0.001)),
      0.02,
    ),
  )
  let repeated = feedback_physics(
    f.runtime,
    f.actor,
    f.geometry,
    f.schedule,
    f.inputs,
    f.target,
    zero,
    0.02,
  )
  for key, a in base.arrays() {
    assert_eq(a.values, repeated.arrays()[key].values)
  }
  assert_true(base.truncated[base.truncated.length() - 1])
}
