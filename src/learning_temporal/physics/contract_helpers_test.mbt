///|
/// Native fixtures are explicit dependencies, never silently skipped. Translation only ran moon check; running these tests later requires a matching MuJoCo library.
fn native_fixture() -> @native_physics.Runtime raise {
  guard @env.get_env_var("MOONROBO_MUJOCO_LIBRARY") is Some(library) else {
    fail(
      "set MOONROBO_MUJOCO_LIBRARY before running native temporal migration contracts",
    )
  }
  @native_physics.Runtime::open(
    library, "src/learning_temporal/physics/testdata/temporal.xml",
  )
}

///|
fn native_actor(
  runtime : @native_physics.Runtime,
  history : Int32,
  future : Int32,
) -> @temporal.TemporalPolicy {
  let (nq, _, _, _) = runtime.dimensions()
  let base = @training.Actor::new(
    { mean: Array::make(9, 0.0), scale: Array::make(9, 1.0), },
    { mean: [0.0], scale: [1.0], },
    [-1.0],
    [1.0],
    0.3,
    {
      q_indices: runtime.q_indices(),
      v_state_indices: runtime.v_indices().map(fn(i) { nq + i }),
      nq,
    },
    8,
    @numeric.Rng::new(4U),
  )
  @temporal.TemporalPolicy::new(base, history, future, 8, @numeric.Rng::new(5U))
}

///|
fn native_value(
  runtime : @native_physics.Runtime,
  actor : @temporal.TemporalPolicy,
) -> @temporal.TemporalValue {
  let (nq, nv, na, _) = runtime.dimensions()
  let model = @training.Dynamics::new(
    {
      mean: Array::make(nq + nv + na, 0.0),
      scale: Array::make(nq + nv + na, 1.0),
    },
    { mean: [0.0], scale: [1.0], },
    { mean: [0.0, 0.0], scale: [1.0, 1.0], },
    8,
    @numeric.Rng::new(7U),
  )
  @temporal.make_value(model, actor, 8, 0.9, 0.2, @numeric.Rng::new(8U))
}

///|
fn fixture_case() -> @native_physics.Case {
  {
    id: "toy",
    family: "train-fixture",
    split: "train",
    motion: "stand",
    keyframe: "home",
    friction: 1.0,
  }
}

///|
fn close_native(
  actual : Array[Double],
  expected : Array[Double],
  tolerance : Double,
) -> Unit raise {
  assert_eq(actual.length(), expected.length())
  for i, x in actual {
    assert_true((x - expected[i]).abs() <= tolerance)
  }
}
