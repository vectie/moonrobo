///|
test "24-axis E1 keeps waist roll and shifts both arm mappings" {
  let robot = profile(joints=24)
  assert_eq(robot.joints[13], "waist_roll_joint")
  assert_eq(robot.joints[14], "l_arm_shoulder_pitch_joint")
  assert_eq(robot.joints[19], "r_arm_shoulder_pitch_joint")
  let q = robot.default_q.copy()
  q[13] = 0.25
  let v = Array::makei(24, i => i.to_double())
  let input = robot.observation(q, v, v, [0.0, 0.0, 0.0], [0.0, 0.0, -1.0], [
    1.0, 0.0, 0.0, 1.0, 0.0, 0.0,
  ])
  assert_eq(input[13], 0.25)
  assert_eq(input[42], 13.0)
  assert_eq(input[77], 13.0)
  assert_eq(input[24:29].to_owned(), Array::make(5, 0.0))
  assert_eq(input[53:58].to_owned(), Array::make(5, 0.0))
  assert_eq(input[88:93].to_owned(), Array::make(5, 0.0))
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP 24-axis gradient check: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let backend = @tensor.Backend::open(path)
  let kin : @aligned.Kinematics = {
    bodies: [
      {
        name: "root",
        parent: -1,
        joint: -1,
        axis: [0.0, 0.0, 1.0],
        offset_p: [0.0, 0.0, 0.0],
        offset_rotation: @aligned.identity(),
        pivot: [0.0, 0.0, 0.0],
        qref: 0.0,
      },
    ],
    tracked: [0],
    q_lo: Array::make(29, -2.0),
    q_hi: Array::make(29, 2.0),
  }
  let context = @geometry.Context::new(
    backend,
    kin,
    -1,
    active_joints=24,
    default_q=robot.embed(robot.default_q),
  )
  let joints = backend.from_values(
    [1, 29],
    Array::make(29, 1.0),
    cuda_device=-1,
    requires_grad=true,
  )
  let zero = backend.from_values(
    [1, 3],
    [0.0, 0.0, 0.0],
    cuda_device=-1,
    requires_grad=false,
  )
  let state : @geometry.State = {
    p: zero,
    rotation: backend.from_values(
      [1, 3, 3],
      @aligned.identity(),
      cuda_device=-1,
      requires_grad=false,
    ),
    v: zero,
    w: zero,
    q: joints,
    qd: joints,
  }
  let projected = context.project_state(state)
  assert_eq(projected.q.values()[13], 1.0)
  assert_eq(projected.q.values()[24:].to_owned(), Array::make(5, 0.0))
  projected.q.sum().backward()
  assert_eq(
    joints.gradient().values(),
    Array::makei(29, i => if i < 24 { 1.0 } else { 0.0 }),
  )
  let policy = @gpu.Policy::new(
    backend,
    99,
    73,
    @numeric.Rng::new(1),
    hist=1,
    hidden=[4],
    active_joints=24,
  )
  let raw_action = backend.from_values(
    [1, 29],
    Array::make(29, 1.0),
    cuda_device=-1,
    requires_grad=true,
  )
  let action = policy.project_actions(raw_action)
  assert_eq(action.values()[13], 1.0)
  assert_eq(action.values()[24:].to_owned(), Array::make(5, 0.0))
  action.sum().backward()
  assert_eq(
    raw_action.gradient().values(),
    Array::makei(29, i => if i < 24 { 1.0 } else { 0.0 }),
  )
}
