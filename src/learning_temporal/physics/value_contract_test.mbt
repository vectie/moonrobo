///|
/// Native episode target reconstruction from test_temporal_value.py.
test "value points end physical return at original task cap and reject held-out labels" {
  let runtime = native_fixture()
  let actor = native_actor(runtime, 3, 2)
  let (nq, nv, na, _) = runtime.dimensions()
  let state = Array::make(nq + nv + na, 0.0)
  state[2] = 0.8
  state[3] = 1.0
  let tape = @numeric.Tape::new()
  let obs = @training.observation(
    tape,
    tape.vector(state),
    tape.vector([0.0]),
    actor.base.body,
  ).map(fn(v) { v.value })
  let steps : Array[@native_physics.Transition] = Array::makei(2, fn(i) {
    {
      time_s: i.to_double() * 0.02,
      state,
      next_state: state,
      observation: obs,
      goal: [0.0],
      applied_action: [0.0],
      terminated: false,
      truncated: i == 1,
      reward: 0.0,
    }
  })
  let episode : @native_physics.Episode = {
    id: "finite-fixture",
    source_family: "train",
    split: "train",
    context: [1.0, 1.0],
    steps,
    case_id: "stand",
    reference_nominal_rad: [0.0],
  }
  let points = episode_value_points(episode, actor, 0.02, 0.04, 0.9, 0.8, fn(
    _,
  ) {
    [0.0]
  })
  assert_eq(points.map(fn(p) { p.remaining }), [0.04, 0.02])
  assert_eq(points[1].target, 3.0)
  let continuation = 1.0 / (1.0 + @math.exp(-22.5)) / (1.0 + @math.exp(-10.0))
  assert_true(
    (points[0].target - (3.0 + 0.9 * continuation * 3.0)).abs() < 1.0e-12,
  )
  let held_out : @native_physics.Episode = { ..episode, split: "test", }
  let rejected : Array[@temporal.ValuePoint]? = Some(
    episode_value_points(held_out, actor, 0.02, 0.04, 0.9, 0.8, fn(_) { [0.0] }),
  ) catch {
    _ => None
  }
  assert_true(rejected.is_none())
}

///|
test "joint-sine previews are seed reproducible bounded and independent of reset RNG" {
  let runtime = native_fixture()
  let raw_case : Json = {
    "id": "sines",
    "family": "train",
    "split": "train",
    "motion": "random_joint_sines",
    "keyframe": "home",
    "friction": 1.0,
    "goal_offset_rad": { "lower": 0.02, "waist": 0.06, "upper": 0.12 },
  }
  let (_, a) = @balance_native.sample_reference(runtime, raw_case, 1)
  let (_, b) = @balance_native.sample_reference(runtime, raw_case, 1)
  let (_, c) = @balance_native.sample_reference(runtime, raw_case, 2)
  assert_eq(a.unwrap().to_json(), b.unwrap().to_json())
  assert_true(a.unwrap().to_json() != c.unwrap().to_json())
  assert_true(a.unwrap().amplitude.all(fn(x) { x >= 0.0 && x <= 0.02 }))
  let reset_rng = @numeric.Rng::new(1U)
  let before = reset_rng.state()
  ignore(@balance_native.sample_reference(runtime, raw_case, 999))
  assert_eq(reset_rng.state(), before)
}
