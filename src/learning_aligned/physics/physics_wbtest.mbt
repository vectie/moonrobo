///|
/// Deferred REAL MuJoCo tests. Set the library, matching G1 scene and real CSV
/// fixture explicitly; missing prerequisites fail rather than claiming physics.
async fn physics_test_fixture() -> (String, String, @aligned.MotionLibrary) {
  guard @env.get_env_var("MOONROBO_MUJOCO_LIBRARY") is Some(library) else {
    fail("deferred aligned physics tests require MOONROBO_MUJOCO_LIBRARY")
  }
  let scene = @env.get_env_var("MOONROBO_ALIGNED_SCENE").unwrap_or(
    "target/learning/g1-aligned-data/g1_description/scene.xml",
  )
  let csv = @env.get_env_var("MOONROBO_ALIGNED_MOTION").unwrap_or(
    "target/learning/g1-aligned-data/lafan1_g1/dance1_subject1.csv",
  )
  let rt = @native_physics.Runtime::open(
    library,
    scene,
    require_position_servos=false,
  )
  let rows = @aligned.parse_motion_csv(
    @utf8.decode(@fs.read_file(csv).binary()),
  )
  guard rows.length() >= 128 else {
    fail("aligned physics fixture needs 128 real reference rows")
  }
  let clip : @aligned.MotionClip = {
    name: "real-fragment",
    sha256: "real-fixture",
    rows: rows[0:128].to_owned(),
  }
  (
    library,
    scene,
    @aligned.MotionLibrary::new([clip], kinematics(rt), source_fps=30.0),
  )
}

///|
fn physics_test_env(
  library : String,
  scene : String,
  motion : @aligned.MotionLibrary,
  context~ : String = "environment",
  count~ : Int32 = 2,
  auto_reset~ : Bool = true,
) -> Environment raise {
  let runtimes = Array::makei(count, _ => {
    @native_physics.Runtime::open(library, scene, require_position_servos=false)
  })
  Environment::new(
    runtimes,
    motion,
    config={
      ..EnvironmentConfig::default(),
      context_resampling: context,
      self_collisions: false,
      reset_noise: false,
      auto_reset,
    },
    seed=7U,
  )
}

///|
async test "source real physics four substeps gain and effort motor contracts" {
  let (library, scene, motion) = physics_test_fixture()
  let env = physics_test_env(library, scene, motion, auto_reset=false)
  env.reset(frames=[0, 0])
  assert_eq(env.substeps, 4)
  let times = env.runtimes.map(rt => rt.integration()[0])
  for rt in env.runtimes {
    let gains = rt.actuator_gain()
    let damping = rt.actuator_damping()
    let armature = rt.joint_armatures()
    let (lower, upper) = rt.actuator_force_bounds()
    for i, name in rt.joint_names() {
      let motor = @aligned.motor_of(name)
      assert_true((gains[i] - motor.stiffness()).abs() < 1.0e-12)
      assert_true((damping[i] - motor.damping()).abs() < 1.0e-12)
      assert_eq(armature[i], motor.armature)
      assert_eq(lower[i], -motor.effort)
      assert_eq(upper[i], motor.effort)
    }
  }
  ignore(env.step(Array::makei(2, _ => Array::make(29, 100.0))))
  for i, rt in env.runtimes {
    assert_true((rt.integration()[0] - times[i] - 0.02).abs() < 1.0e-12)
    for j, name in rt.joint_names() {
      assert_true(
        rt.actuator_force()[j].abs() <= @aligned.motor_of(name).effort + 1.0e-10,
      )
    }
  }
}

///|
async test "source fixed environment context keeps friction COM but resets calibration" {
  let (library, scene, motion) = physics_test_fixture()
  let env = physics_test_env(library, scene, motion)
  let before = env.xi.map(row => row.copy())
  let mut torso = -1
  for i in 0..<env.runtimes[0].body_count() {
    if env.runtimes[0].body_name(i) == "torso_link" {
      torso = i
    }
  }
  assert_true(torso >= 0)
  let base = Array::makei(env.runtimes.length(), i => {
    @aligned.vec_sub(
      env.runtimes[i].body_inertial_pos(torso),
      env.xi[i][30:33].to_owned(),
    )
  })
  env.reset(frames=[0, 0])
  for i in 0..<2 {
    assert_eq(env.runtimes[i].geom_friction("floor")[0], 0.3)
    for j in [0, 30, 31, 32] {
      assert_eq(before[i][j], env.xi[i][j])
    }
    assert_true(before[i][1:30] != env.xi[i][1:30])
    let expected = @aligned.vec_add(base[i], env.xi[i][30:33].to_owned())
    assert_true(
      @aligned.vec_sub(env.runtimes[i].body_inertial_pos(torso), expected).fold(
        init=0.0,
        (sum, x) => sum + x * x,
      ) <
      1.0e-24,
    )
  }
}

///|
async test "source episode context resamples selected environment only and restore is exact" {
  let (library, scene, motion) = physics_test_fixture()
  let env = physics_test_env(library, scene, motion, context="episode")
  let before = env.xi.map(row => row.copy())
  env.reset(ids=[0], frames=[0])
  assert_eq(before[1], env.xi[1])
  assert_true([0, 30, 31, 32].any(j => before[0][j] != env.xi[0][j]))
  let saved = env.snapshot()
  ignore(env.step(Array::makei(2, _ => Array::make(29, 0.0))))
  assert_true(env.restore(saved))
  assert_eq(env.snapshot().to_json(), saved.to_json())
  assert_true(
    (try? env.restore({
      ..saved,
      config: { ..saved.config, context_resampling: "environment", },
    }))
    is Err(_),
  )
}

///|
async test "source CPU scale and SMC profile semantics remain explicitly separate" {
  let paper = @json.parse(
    @utf8.decode(
      @fs.read_file("examples/learning/g1-aligned-scale.json").binary(),
    ),
  )
  let smc = @json.parse(
    @utf8.decode(@fs.read_file("examples/learning/g1-smc-scale.json").binary()),
  )
  guard paper is Object(p) && smc is Object(s) else { fail("profile objects") }
  assert_eq(p["observation_mode"], "paper".to_json())
  assert_eq(p["wm_only_iters"], (0).to_json())
  assert_eq(s["observation_mode"], "smc".to_json())
  assert_eq(s["wm_only_iters"], (500).to_json())
  assert_eq(s["context_resampling"], "environment".to_json())
  assert_eq(s["self_collisions"], false.to_json())
  assert_eq(s["amp"], "bf16".to_json())
  for fields in [p, s] {
    assert_eq(fields["physics_dt"], 0.005.to_json())
    assert_eq(fields["wm_hidden"], [2048, 2048, 2048].to_json())
    assert_eq(fields["horizon"], (32).to_json())
  }
}

///|
async test "source REAL split training matches uninterrupted learner replay history and RNG" {
  let (library, scene, motion) = physics_test_fixture()
  let env = physics_test_env(library, scene, motion, count=1)
  let split_env = physics_test_env(library, scene, motion, count=1)
  let d = @aligned.LearnerConfig::default()
  let config = {
    ..d,
    wm_hidden: [4],
    policy_hidden: [4],
    critic_hidden: [4],
    hist: 2,
    goal_frames: 1,
    horizon: 2,
    wm_window: 2,
    wm_batches: 1,
    wm_batch: 1,
    policy_batch: 1,
    critic_epochs: 1,
    critic_minibatches: 1,
    observation_noise: false,
  }
  let full = @aligned.TrainingRunner::new(
    @aligned.Learner::new(env.kin, motion, config~, seed=7U),
    16,
    1,
  )
  let split = @aligned.TrainingRunner::new(
    @aligned.Learner::new(split_env.kin, motion, config~, seed=7U),
    16,
    1,
  )
  let options : @aligned.TrainingOptions = {
    iterations: 3,
    warmup_steps: 4,
    world_only_iterations: 1,
    update_to_data: 0.4,
    learning_rate_decay_iterations: 20,
    action_noise: 0.1,
  }
  let rows = []
  full.run(options, () => env.inspect(), a => env.step(a), m => {
    rows.push(m.report_json())
  })
  split.run(
    { ..options, iterations: 2, },
    () => split_env.inspect(),
    a => split_env.step(a),
    _ => (),
  )
  let saved = split.checkpoint({}, split_env.snapshot().to_json())
  let restored_env = physics_test_env(library, scene, motion, count=1)
  let restored = @aligned.TrainingRunner::new(
    @aligned.Learner::new(restored_env.kin, motion, config~, seed=7U),
    16,
    1,
  )
  let physics : EnvironmentSnapshot = @json.from_json(saved.environment)
  let exact = restored_env.restore(physics)
  assert_true(exact)
  restored.restore(saved, exact)
  restored.run(
    options,
    () => restored_env.inspect(),
    a => restored_env.step(a),
    _ => (),
  )
  assert_eq(
    full.checkpoint({}, env.snapshot().to_json()).to_json(),
    restored.checkpoint({}, restored_env.snapshot().to_json()).to_json(),
  )
  assert_eq(full.counters.actor_updates, 2)
  guard rows[0] is Object(first) && rows[1] is Object(second) else {
    fail("iteration rows")
  }
  assert_true(!first.contains("policy") && second.contains("policy"))
}

///|
fn physics_test_norm2(values : Array[Double]) -> Double {
  values.fold(init=0.0, (s, x) => s + x * x)
}

///|
async test "parent MDP FK poses velocities and joint pullbacks match real MuJoCo" {
  let (library, scene, _) = physics_test_fixture()
  let rt = @native_physics.Runtime::open(
    library,
    scene,
    require_position_servos=false,
  )
  let kin = kinematics(rt)
  let layout = joint_layout(rt)
  let s : @aligned.State = {
    p: [0.1, 0.1, 0.88],
    rotation: @aligned.so3_exp([0.3, -0.2, 0.4]),
    v: [0.2, -0.3, 0.4],
    w: [0.2, 0.2, 0.2],
    q: Array::makei(29, i => {
      @aligned.default_joint_positions()[i] - 0.1 + 0.2 * i.to_double() / 28.0
    }),
    qd: Array::makei(29, i => -0.2 + 0.4 * i.to_double() / 28.0),
  }
  let raw = @aligned.mujoco_state(@aligned.flatten_state(s), layout)
  rt.set_state(raw)
  let expected = kin.forward(s)
  let names = @aligned.tracked_body_names()
  let ids = names.map(name => {
    let mut id = -1
    for i in 0..<rt.body_count() {
      if rt.body_name(i) == name {
        id = i
      }
    }
    guard id >= 0 else { fail("tracked body") }
    id
  })
  for i, id in ids {
    let pos = rt.body_world_pos(id)
    let rotation = @aligned.quat_to_mat(rt.body_world_quat(id))
    assert_true(
      physics_test_norm2(@aligned.vec_sub(expected[i].p, pos)).sqrt() < 1.0e-10,
    )
    assert_true(
      physics_test_norm2(@aligned.vec_sub(expected[i].rotation, rotation)).sqrt() <
      1.0e-10,
    )
    let jac = rt.point_jacobian(pos, id)
    let linear = jac.map(row => {
      Array::makei(layout.nv, j => row[j] * raw[layout.nq + j]).fold(init=0.0, (
        a,
        b,
      ) => a + b)
    })
    assert_true(
      physics_test_norm2(@aligned.vec_sub(expected[i].v, linear)).sqrt() <
      1.0e-10,
    )
    let angular = rt.body_object_velocity_world(id)[0:3].to_owned()
    assert_true(
      physics_test_norm2(@aligned.vec_sub(expected[i].w, angular)).sqrt() <
      1.0e-10,
    )
  }
  let gradient = kin.position_square_gradient(s)
  assert_true(gradient.all(v => !v.is_nan() && !v.is_inf()))
  assert_true(gradient.fold(init=0.0, (sum, x) => sum + x.abs()) > 0.0)
  for j in 0..<29 {
    let values = []
    for epsilon in [-0.000001, 0.000001] {
      let q = s.q.copy()
      q[j] += epsilon
      rt.set_state(
        @aligned.mujoco_state(@aligned.flatten_state({ ..s, q, }), layout),
      )
      values.push(
        ids
        .map(id => physics_test_norm2(rt.body_world_pos(id)))
        .fold(init=0.0, (a, b) => a + b),
      )
    }
    assert_true(
      (gradient[j] - (values[1] - values[0]) / 0.000002).abs() < 0.00001,
    )
  }
  let decoded = @aligned.unflatten_state(@aligned.flatten_state(s))
  for
    (a, b) in [
      (s.p, decoded.p),
      (s.rotation, decoded.rotation),
      (s.v, decoded.v),
      (s.w, decoded.w),
      (s.q, decoded.q),
      (s.qd, decoded.qd),
    ] {
    assert_true(physics_test_norm2(@aligned.vec_sub(a, b)).sqrt() < 1.0e-12)
  }
}
