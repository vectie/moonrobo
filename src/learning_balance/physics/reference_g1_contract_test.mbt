///|
/// Original Menagerie G1 fixture contract from test_full_body_reference.py.
/// This intentionally requires the original external model path (or an explicit
/// MOONROBO_G1_SCENE override), and does not silently skip when assets are absent.
/// The checked-in one-hinge contracts remain useful independently of Menagerie.
fn g1_fixture() -> @native_physics.Runtime raise {
  let scene = @env.get_env_var("MOONROBO_G1_SCENE").unwrap_or(
    "target/mujoco_menagerie/unitree_g1/scene_mjx.xml",
  )
  @native_physics.Runtime::open(fixture_library(), scene)
}

///|
test "original G1 reference preserves replay next-frame preview 93 observation and 29 setpoints" {
  let runtime = g1_fixture()
  let reference = recorded_reference(runtime)
  let case : @native_physics.Case = {
    id: "stand",
    family: "procedural-stand",
    motion: "stand",
    keyframe: "home",
    split: "train",
    friction: 1.0,
  }
  assert_eq(reference.q_indices.length(), 29)
  let (source, source_trial) = replay_reference(
    runtime, reference, case, 7, "source-setpoint",
  )
  assert_eq(source.steps.length(), reference.controls.length() - 7)
  assert_false(source.steps[source.steps.length() - 1].terminated)
  assert_true(source.steps[source.steps.length() - 1].truncated)
  let source_fields = match source_trial {
    Object(fields) => fields
    _ => fail("reference source trial must be an object")
  }
  let maximum : Double = @json.from_json(
    source_fields["max_state_component_error"],
  )
  assert_true(maximum < 1.0e-10)
  assert_eq(source.steps[0].goal, reference.reference.goals[8])
  let (tail, valid) = reference.reference.preview(
    reference.controls.length() - 2,
    length=4,
  )
  assert_eq(valid, [true, true, false, false])
  let goals = reference.reference.goals
  assert_eq(tail, [
    goals[goals.length() - 2],
    goals[goals.length() - 1],
    goals[goals.length() - 1],
    goals[goals.length() - 1],
  ])
  let altered = reference.controls.map(fn(row) { row.map(fn(x) { x + 100.0 }) })
  let changed = NativeReference::new(
    runtime,
    reference.frames,
    altered,
    reference.observations,
    reference.reference.dt,
  )
  assert_eq(changed.reference.goals, goals)
  let previews : Array[Array[Bool]] = []
  let policy = fn(
    obs : Array[Double],
    current : Array[Double],
    future : Array[Array[Double]],
    mask : Array[Bool],
  ) -> Array[Double] {
    assert_eq(obs.length(), 93) catch {
      _ => abort("original G1 observation must have 93 components")
    }
    assert_eq(current.length(), goals[0].length()) catch {
      _ => abort("G1 goal layout changed")
    }
    assert_eq(future.length(), 10) catch {
      _ => abort("G1 preview must contain ten goals")
    }
    for row in future {
      assert_eq(row.length(), goals[0].length()) catch {
        _ => abort("G1 preview goal layout changed")
      }
    }
    previews.push(mask)
    future[0][:29].to_owned()
  }
  let (actual, trial) = replay_reference(
    runtime,
    reference,
    case,
    7,
    "policy",
    policy~,
  )
  let (expected, _) = replay_reference(
    runtime, reference, case, 7, "joint-position",
  )
  assert_eq(actual.steps.to_json(), expected.steps.to_json())
  assert_true(previews[0].all(fn(x) { x }))
  assert_eq(previews[previews.length() - 1].filter(fn(x) { x }).length(), 1)
  let fields = match trial {
    Object(fields) => fields
    _ => fail("reference policy trial must be an object")
  }
  let tracking : @balance.TrackingTrial = {
    case_id: "stand",
    origin: 7,
    failed: @json.from_json(fields["failed"]),
    simulated_seconds: @json.from_json(fields["simulated_seconds"]),
    requested_seconds: @json.from_json(fields["requested_seconds"]),
    metrics: { "joint_rmse_rad": @json.from_json(fields["joint_rmse_rad"]) },
  }
  assert_true(
    @balance.assess_tracking_quality([tracking], [("stand", 7)], {
      "joint_rmse_rad": 1.0,
    }).0,
  )
  assert_false(
    @balance.assess_tracking_quality([], [("stand", 7)], {
      "joint_rmse_rad": 1.0,
    }).0,
  )
  assert_false(
    @balance.assess_tracking_quality([tracking, tracking], [("stand", 7)], {
      "joint_rmse_rad": 1.0,
    }).0,
  )
  let frame = reference.frames[5]
  let rotation = @balance.rotation_vector([0.0, 0.0, 0.83])
  let state = frame.state.copy()
  let velocity = @balance.matvec(
    rotation,
    state[reference.nq:reference.nq + 3].to_owned(),
  )
  for j in 0..<3 {
    state[reference.nq + j] = velocity[j]
  }
  let positions = frame.body_position.map(fn(row) {
    let rotated = @balance.matvec(rotation, row)
    [rotated[0] + 7.0, rotated[1] - 12.0, rotated[2]]
  })
  let rotations = frame.body_rotation.map(fn(row) {
    @balance.matmul(rotation, row)
  })
  let encoded = @balance.encode_goal(
    state,
    positions,
    rotations,
    reference.q_indices,
    reference.v_indices,
    reference.nq,
    reference.root_index,
  )
  for j, x in encoded {
    assert_true(
      (x - goals[5][j]).abs() <= 3.0e-15 + 1.0e-12 * goals[5][j].abs(),
    )
  }
}
