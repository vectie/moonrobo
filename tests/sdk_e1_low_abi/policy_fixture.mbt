///|
fn run_policy_fixture(controller : @low.Controller) -> Unit raise {
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
  let robot : Json = {
    "format": "moonrobo.lunakine-e1.v1",
    "identity": {
      "robot": {
        "format": "moonrobo.e1-embedded-profile.v1",
        "id": "synthetic-only",
        "joints": Json(Array::makei(23, i => "joint_\{i}")),
        "default_q": Json(Array::make(23, 0.0)),
        "scales": Json(Array::make(23, 1.0)),
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
        "default_q": Json(Array::make(23, 0.0)),
      },
      "internal_actions": 29,
      "physical_actions": 23,
      "observation_mode": "smc",
      "internal_observation_width": 99,
      "joint_velocity_feature_scale": 0.1,
      "body_gyro_feature_scale": 0.25,
    },
  }
  let bundle = @actor.Bundle::parse(Json(spec), robot)
  let calibration : @policy.Calibration = {
    format: "moonrobo.e1-sdk-calibration.v1",
    profile_id: "synthetic-only",
    axes: Array::makei(23, index => {
      actor_joint: "joint_\{index}",
      sdk_joint: "fixture_slot_\{23 - index}",
      motor_id: 100 + 23 - index,
      direction: if index % 2 == 0 {
        -1.0
      } else {
        1.0
      },
      zero: 0.25,
      kp: (10 + index).to_double(),
      kd: (1 + index).to_double(),
    }),
    fixed: [
      {
        sdk_joint: "fixture_slot_0",
        motor_id: 100,
        position: 100.0,
        velocity: 10.0,
        torque: 20.0,
        kp: 30.0,
        kd: 40.0,
      },
    ],
  }
  let mapping = @policy.Mapping::new(bundle, calibration, resolve=name => {
    controller.joint_index(name)
  })
  let sample = @low.Sample::new()
  ignore(controller.joint_index("fixture_policy_clean"))
  controller.capture_into(sample)
  let (q, qd) = mapping.joint_state(sample)
  for i in 0..<23 {
    let direction = if i % 2 == 0 { -1.0 } else { 1.0 }
    assert_eq(q[i], direction * (23 - i).to_double())
    assert_eq(qd[i], direction * ((23 - i).to_double() + 0.5))
  }
  let identity = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]
  let observer = @policy.Observer::new(
    mapping,
    @policy.Imu::new({
      quaternion_order: "wxyz",
      orientation_direction: "sensor_to_world",
      gyro_frame: "sensor",
      gyro_to_radians: 1.0,
      sensor_to_body: identity,
      world_to_actor_world: identity,
    }),
  )
  let previous = Array::makei(29, i => (i + 1).to_double())
  let observation = observer.observation(sample, previous[:], identity[:])
  assert_eq(observation.length(), 99)
  for i in 0..<23 {
    assert_eq(observation[i], q[i])
    assert_eq(observation[29 + i], qd[i] * 0.1)
    assert_eq(observation[64 + i], previous[i])
  }
  for i in 23..<29 {
    assert_eq(
      (observation[i], observation[29 + i], observation[64 + i]),
      (0.0, 0.0, 0.0),
    )
  }
  assert_eq(observation[58:61].to_owned(), [1.5, 1.75, 2.0])
  let expected = [
    -7.0 / 27.0,
    -26.0 / 27.0,
    -2.0 / 27.0,
    -14.0 / 27.0,
    22.0 / 27.0,
    2.0 / 27.0,
    -7.0 / 27.0,
    23.0 / 27.0,
    14.0 / 27.0,
  ]
  for i in 0..<9 {
    let actual = observation[if i < 3 { 61 + i } else { 93 + i - 3 }]
    assert_true((actual - expected[i]).abs() < 1.0e-12)
  }
  let commands = mapping.commands(Array::makei(29, i => (i + 1).to_double())[:])
  controller.publish(commands)
  assert_eq(controller.joint_index("fixture_publish_count"), 3)
  for hook in ["fixture_policy_wrong_id", "fixture_policy_error"] {
    ignore(controller.joint_index(hook))
    controller.capture_into(sample)
    try mapping.joint_state(sample) catch {
      _ => ()
    } noraise {
      _ => fail("unqualified SDK state accepted")
    }
    assert_eq(controller.joint_index("fixture_publish_count"), 3)
  }
  ignore(controller.joint_index("fixture_policy_clean"))
  controller.capture_into(sample)
  ignore(mapping.joint_state(sample))
  controller.publish(commands)
  assert_eq(controller.joint_index("fixture_publish_count"), 4)
  let parameters = Array::make(spec.parameter_count(), 0.0)
  for i in 0..<29 {
    parameters[parameters.length() - 29 + i] = (i + 1).to_double()
  }
  let actor = @actor.Actor::reference(
    bundle,
    @portable.encode_parameters(parameters[:])[:],
  )
  defer actor.close()
  let clock = () => @env.now().reinterpret_as_int64()
  let sensor = @control.Sensor::from_sdk(controller, observer, clock~)
  let supervisor = @skills.Supervisor::new("control-fixture", [
    {
      id: "one",
      description: "synthetic composed control",
      reference_id: "fixed-preview",
      maximum_duration_ms: 1000,
      parameters: [],
    },
  ])
  let stops = Ref(0)
  let stored_frame : Json = {
    "goals": Json(Array::make(73, 0.0)),
    "body_to_world": Json(identity),
  }
  let clip = @reference.Clip::parse(bundle, {
    "format": "moonrobo.e1-actor-reference.v1",
    "profile_id": bundle.profile_id(),
    "joints": Json(bundle.joints()),
    "reference_id": "fixed-preview",
    "control_dt_ms": 20,
    "goal_layout": "aligned.preview73.v1",
    "frames": Json([stored_frame, stored_frame]),
  })
  let runner = @control.new_runner(
    supervisor,
    actor,
    mapping,
    sensor,
    reference=(execution, step, _) => {
      let frame = clip.frame(execution, step)
      {
        goals: frame.goals,
        body_to_world: frame.body_to_world,
        complete: frame.complete,
      }
    },
    publish=frame => controller.publish(frame),
    stop=() => stops.val += 1,
  )
  let now = clock()
  ignore(
    supervisor.accept(
      {
        request_id: "composed-one",
        sequence: 0L,
        catalog_id: "control-fixture",
        context_version: supervisor.version(),
        expires_at_ms: now + 1000L,
        proposal: { skill_id: "one", parameters: Map([]), },
      },
      now,
    ),
  )
  ignore(controller.joint_index("fixture_policy_clean"))
  assert_true(runner.tick() is Action(_))
  assert_eq(controller.joint_index("fixture_publish_count"), 5)
  assert_true(runner.tick() is Stopped)
  assert_eq(stops.val, 1)
  assert_true(supervisor.snapshot(clock()) is Some({ state: Completed, .. }))
  assert_eq(controller.joint_index("fixture_publish_count"), 5)
  println(
    "SDK3.1 composed control ABI: task -> timed coherent capture -> calibrated99D features -> numerical actor ->24 mapped commands -> fake SDK, then reference completion/stop notification passed; no physical stop claim",
  )
  println(
    "SDK3.1 calibrated policy ABI: reversed slots, signs/zeros/gains, explicit extra motor, raw-state conversion, identity/error rejection and full-frame publication passed; synthetic calibration/fake SDK only",
  )
  println(
    "SDK3.1 sensor ABI: calibrated joints/quaternion/gyro -> saved legacy scales ->99D observation passed; synthetic calibration/fake SDK only",
  )
}
