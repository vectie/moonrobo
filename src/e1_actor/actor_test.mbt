///|
fn fixture(
  velocity_scale~ : Double = 1.0,
  gyro_scale~ : Double = 1.0,
) -> (@e1_actor.Bundle, Bytes) raise {
  let spec : @portable.Spec = {
    format: "lunakine.elu-actor.v1",
    history_frames: 1,
    observation_width: 99,
    encoder: [73, 32],
    decoder: [131, 29],
    observation_norm: {
      mean: Array::make(99, 0.0),
      variance: Array::make(99, 1.0),
      epsilon: 0.01,
    },
    goal_norm: {
      mean: Array::make(73, 0.0),
      variance: Array::make(73, 1.0),
      epsilon: 0.01,
    },
    action_mask: Array::makei(29, i => if i < 23 { 1.0 } else { 0.0 }),
  }
  let companion : Json = {
    "format": "moonrobo.lunakine-e1.v1",
    "identity": {
      "robot": {
        "format": "moonrobo.e1-embedded-profile.v1",
        "id": "synthetic-only",
        "joints": Json(Array::makei(23, i => "joint_\{i}")),
        "default_q": Json(Array::makei(23, i => i.to_double() * 0.1)),
        "scales": Json(Array::make(23, 0.01)),
      },
    },
    "source_spec": {
      "format": "moonrobo.native-tensor-actor-spec.v1",
      "observation_mode": "smc",
      "hist": 1,
      "goal_frames": 1,
    },
    "physical_action_count": 23,
    "contract": {
      "profile": {
        "id": "synthetic-only",
        "joints": Json(Array::makei(23, i => "joint_\{i}")),
        "default_q": Json(Array::makei(23, i => i.to_double() * 0.1)),
      },
      "internal_actions": 29,
      "physical_actions": 23,
      "observation_mode": "smc",
      "internal_observation_width": 99,
      "joint_velocity_feature_scale": velocity_scale,
      "body_gyro_feature_scale": gyro_scale,
    },
  }
  let values = Array::make(spec.parameter_count(), 0.0)
  for i in 0..<29 {
    values[values.length() - 29 + i] = (i + 1).to_double()
  }
  (
    @e1_actor.Bundle::parse(Json(spec), companion),
    @portable.encode_parameters(values[:]),
  )
}

///|
test "deployment-only actor projects physical actions converts nominal positions and closes" {
  let (bundle, parameters) = fixture()
  assert_eq(bundle.profile_id(), "synthetic-only")
  assert_eq(bundle.history_frames(), 1)
  assert_eq(bundle.observation_width(), 99)
  assert_eq(bundle.goal_width(), 73)
  assert_eq(bundle.joints().length(), 23)
  let actor = @e1_actor.Actor::reference(bundle, parameters[:])
  let history = [Array::make(99, 0.0)]
  let goals = Array::make(73, 0.0)
  let action = actor.forward_embedded(history, goals)
  assert_eq(
    action,
    Array::makei(29, i => if i < 23 { (i + 1).to_double() } else { 0.0 }),
  )
  assert_eq(actor.forward(history, goals).length(), 23)
  let q = bundle.nominal_setpoints(action[:])
  assert_eq(q[0], 0.01)
  assert_true((q[22] - 2.43).abs() < 1.0e-12)
  try actor.forward_embedded([], goals) catch {
    _ => ()
  } noraise {
    _ => fail("invalid history accepted")
  }
  assert_eq(actor.bundle().profile_id(), bundle.profile_id())
  try
    @e1_actor.Actor::open_ascend(
      bundle, "/moonrobo-missing-ascend-reference-fixture.so", "not-a-real-model.om",
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("unavailable Ascend runtime silently fell back")
  }
  actor.close()
  actor.close()
  try actor.forward_embedded(history, goals) catch {
    _ => ()
  } noraise {
    _ => fail("closed actor accepted inference")
  }
}

///|
async test "real exported bundle loads through deployment-only reference" {
  guard @env.get_env_var("MOONROBO_E1_BUNDLE") is Some(directory) else {
    println("SKIP trained E1 deployment: set MOONROBO_E1_BUNDLE")
    return
  }
  let bundle = @e1_actor.Bundle::read(directory)
  let actor = @e1_actor.Actor::reference(
    bundle,
    @fs.read_file(directory + "/parameters.f32").binary()[:],
  )
  defer (actor.close() catch { _ => () })
  let actions = actor.forward_embedded(
    Array::makei(bundle.history_frames(), _ => {
      Array::make(bundle.observation_width(), 0.0)
    }),
    Array::make(bundle.goal_width(), 0.0),
  )
  assert_eq(actions.length(), 29)
  assert_true(actions.all(@portable.finite))
  assert_eq(
    bundle.nominal_setpoints(actions[:]).length(),
    bundle.joints().length(),
  )
  for index in bundle.joints().length()..<29 {
    assert_eq(actions[index], 0.0)
  }
}
