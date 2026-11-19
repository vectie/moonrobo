///|
test "dummy actions and model-state gradients are zero; physical channels retain gradients" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP E1 tensor projection: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let backend = @tensor.Backend::open(path)
  let robot = profile()
  let root : @aligned.BodySpec = {
    name: "base_link",
    parent: -1,
    joint: -1,
    axis: [0.0, 0.0, 1.0],
    offset_p: [0.0, 0.0, 0.0],
    offset_rotation: @aligned.identity(),
    pivot: [0.0, 0.0, 0.0],
    qref: 0.0,
  }
  let kin : @aligned.Kinematics = {
    bodies: [root],
    tracked: [0],
    q_lo: Array::make(29, -2.0),
    q_hi: Array::make(29, 2.0),
  }
  let context = @geometry.Context::new(
    backend,
    kin,
    -1,
    active_joints=23,
    default_q=robot.embed(robot.default_q),
  )
  assert_eq(context.default_joint_values(), robot.embed(robot.default_q))
  let base = state_of_row(
    [0.0, 0.0, 0.8, 0.0, 0.0, 0.0, 1.0] + robot.embed(robot.default_q),
  )
  let fixed_context = context
    .with_heading_mode(OrthonormalAtlas)
    .with_rotation_error_mode(GeodesicSquared)
  let zeros = Array::make(29, 0.0)
  let actions = backend.from_values(
    [1, 29],
    zeros,
    cuda_device=-1,
    requires_grad=false,
    dtype=Float32,
  )
  fn as_tensor(s : @aligned.State) -> @geometry.State raise {
    @geometry.State::from_flat71(
      backend,
      backend.from_values(
        [1, 71],
        @aligned.flatten_state(s),
        cuda_device=-1,
        requires_grad=false,
        dtype=Float32,
      ),
    )
  }
  let mut max_heading_difference = 0.0
  for tilt in [0.0, 0.75, 1.5707963267948966, 3.13] {
    let s = {
      ..base,
      rotation: @aligned.mat_mul(
        @aligned.so3_exp([0.0, tilt, 0.0]),
        @aligned.so3_exp([0.55, 0.0, 0.0]),
      ),
    }
    let physical = @aligned.reward(
      kin,
      s,
      base,
      kin.forward(base),
      zeros,
      zeros,
      atlas=true,
    )
    let legacy = @aligned.reward(kin, s, base, kin.forward(base), zeros, zeros)
    max_heading_difference = max_heading_difference.max(
      (legacy.body_ori - physical.body_ori).abs(),
    )
    let imagined = fixed_context.reward_terms(
      as_tensor(s),
      as_tensor(base),
      actions,
      actions,
    )
    assert_true(
      (physical.body_ori - imagined.body_ori.values()[0]).abs() < 1.0e-4,
    )
    assert_true((physical.reward - imagined.reward.values()[0]).abs() < 1.0e-6)
  }
  assert_true(max_heading_difference > 0.01)
  let history = backend.from_values(
    [2, 10, 99],
    Array::make(1980, 1.0),
    cuda_device=-1,
    requires_grad=false,
    dtype=Float32,
  )
  let projected_history = context.project_observation(history).values()
  for i, x in projected_history {
    let j = i % 99
    assert_eq(
      x,
      if (j >= 23 && j < 29) || (j >= 52 && j < 58) || (j >= 87 && j < 93) {
        0.0
      } else {
        1.0
      },
    )
  }
  let legacy = @geometry.Context::new(backend, kin, -1)
  assert_eq(legacy.default_joint_values(), @aligned.default_joint_positions())
  let q = backend.from_values(
    [1, 29],
    Array::make(29, 1.0),
    cuda_device=-1,
    requires_grad=true,
    dtype=Float32,
  )
  let rotation = backend.from_values(
    [1, 3, 3],
    @aligned.identity(),
    cuda_device=-1,
    requires_grad=false,
    dtype=Float32,
  )
  let zero = backend.from_values(
    [1, 3],
    [0.0, 0.0, 0.0],
    cuda_device=-1,
    requires_grad=false,
    dtype=Float32,
  )
  let state : @geometry.State = {
    p: zero,
    rotation,
    v: zero,
    w: zero,
    q,
    qd: q,
  }
  let projected = context.project_state(state)
  assert_eq(projected.q.values()[23:].to_owned(), Array::make(6, 0.0))
  projected.q.sum().backward()
  assert_eq(
    q.gradient().values(),
    Array::makei(29, i => if i < 23 { 1.0 } else { 0.0 }),
  )
  let policy = @gpu.Policy::new(
    backend,
    99,
    730,
    @numeric.Rng::new(1U),
    hidden=[8],
    active_joints=23,
  )
  let action = policy.forward(
    backend.from_values(
      [1, 10, 99],
      Array::make(990, 0.0),
      cuda_device=-1,
      requires_grad=false,
      dtype=Float32,
    ),
    backend.from_values(
      [1, 730],
      Array::make(730, 0.0),
      cuda_device=-1,
      requires_grad=false,
      dtype=Float32,
    ),
  )
  assert_eq(action.values()[23:].to_owned(), Array::make(6, 0.0))
}
