///|
/// Native contracts from test_balance_features.py and test_balance_teacher.py. Running requires MOONROBO_MUJOCO_LIBRARY; no tests have been executed during translation.
fn fixture_library() -> String raise {
  guard @env.get_env_var("MOONROBO_MUJOCO_LIBRARY") is Some(library) else {
    fail(
      "set MOONROBO_MUJOCO_LIBRARY to the matching native MuJoCo shared library before running native migration tests",
    )
  }
  library
}

///|
fn close_array(
  actual : Array[Double],
  expected : Array[Double],
  tolerance : Double,
) -> Unit raise {
  assert_eq(actual.length(), expected.length())
  for i, x in actual {
    assert_true((x - expected[i]).abs() <= tolerance)
  }
}

///|
/// Original NumPy geometry tolerance, including its relative component.
fn close_geometry(
  actual : Array[Double],
  expected : Array[Double],
) -> Unit raise {
  assert_eq(actual.length(), expected.length())
  for i, x in actual {
    assert_true(
      (x - expected[i]).abs() <= 1.0e-13 + 1.0e-12 * expected[i].abs(),
    )
  }
}

///|
test "static geometry matches MuJoCo for anchor reference arbitrary root and fixed descendants" {
  let runtime = @native_physics.Runtime::open(
    fixture_library(),
    "src/learning_balance/physics/testdata/balance.xml",
  )
  let geometry = make_spec(runtime)
  assert_eq(geometry.nu, 1)
  let rng = @numeric.Rng::new(21U)
  runtime.reset("home", 1.0)
  for _ in 0..<32 {
    let state = runtime.state()
    for j in 0..<3 {
      state[j] = -20.0 + 40.0 * rng.uniform()
    }
    let q = Array::makei(4, fn(_) { rng.normal() })
    let norm = @balance.dot(q, q).sqrt()
    for j in 0..<4 {
      state[3 + j] = q[j] / norm
    }
    state[7] = -0.4 + 1.1 * rng.uniform()
    runtime.set_state(state)
    let root = runtime.root_body()
    let rotation = @balance.quaternion_matrix(runtime.body_world_quat(root))
    let inverse = @balance.transpose(rotation)
    let root_pos = runtime.body_world_pos(root)
    let com = runtime.subtree_com(root)
    let (actual_com, actual_feet) = geometry.geometry([state[7]])
    close_geometry(
      actual_com,
      @balance.matvec(inverse, Array::makei(3, fn(j) { com[j] - root_pos[j] })),
    )
    let feet : Array[Array[Double]] = []
    for name in ["left_foot", "right_foot"] {
      let mut site = -1
      for i in 0..<runtime.site_count() {
        if runtime.site_name(i) == name {
          site = i
        }
      }
      assert_true(site >= 0)
      feet.push(runtime.site_world_pos(site))
    }
    for i, foot in feet {
      close_geometry(
        actual_feet[i],
        @balance.matvec(
          inverse,
          Array::makei(3, fn(j) { foot[j] - root_pos[j] }),
        ),
      )
    }
    let error = [
      com[0] - (feet[0][0] + feet[1][0]) / 2.0,
      com[1] - (feet[0][1] + feet[1][1]) / 2.0,
      0.0,
    ]
    close_geometry(
      geometry.from_observation(runtime.observation([0.0])),
      @balance.matvec(inverse, error),
    )
  }
}

///|
test "real support Jacobian compensation leaves free base generalized torque zero" {
  let runtime = @native_physics.Runtime::open(
    fixture_library(),
    "src/learning_balance/physics/testdata/teacher.xml",
  )
  runtime.reset("home", 1.0)
  let state = runtime.state()
  for i in runtime.q_indices() {
    state[i] = 0.02
  }
  runtime.set_state(state)
  let sites : Array[Int32] = []
  for name in ["left_foot", "right_foot"] {
    for i in 0..<runtime.site_count() {
      if runtime.site_name(i) == name {
        sites.push(i)
      }
    }
  }
  assert_eq(sites.length(), 2)
  let feet = sites.map(fn(i) { runtime.site_world_pos(i) })
  let com = runtime.subtree_com(runtime.root_body())
  let cop = @balance.clip(
    com[0],
    (feet[0][0] + feet[1][0]) / 2.0 - 0.04,
    (feet[0][0] + feet[1][0]) / 2.0 + 0.04,
  )
  let jacobian = sites.mapi(fn(i, site) {
    let point = feet[i].copy()
    point[0] = cop
    runtime.point_jacobian(point, runtime.site_body(site))[2]
  })
  let mut mass = 0.0
  for i in 1..<runtime.body_count() {
    mass += runtime.body_mass(i)
  }
  let before = runtime.state()
  let force_before = runtime.actuator_force()
  let applied_before = runtime.qfrc_applied()
  let torque = @balance.support_torque(
    com,
    feet,
    mass * -runtime.gravity()[2],
    jacobian,
    runtime.qfrc_bias(),
  )
  for i in 0..<6 {
    assert_true(torque[i].abs() < 1.0e-10)
  }
  assert_true(torque[6:].fold(init=0.0, fn(sum, x) { sum + x * x }) > 1.0e-4)
  assert_eq(runtime.state(), before)
  assert_eq(runtime.actuator_force(), force_before)
  assert_eq(runtime.qfrc_applied(), applied_before)
}
