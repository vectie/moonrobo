///|
fn fixture(count : Int32) -> @actor.Bundle raise {
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
    action_mask: Array::makei(29, i => if i < count { 1.0 } else { 0.0 }),
  }
  let robot : Json = {
    "format": "moonrobo.lunakine-e1.v1",
    "identity": {
      "robot": {
        "format": "moonrobo.e1-embedded-profile.v1",
        "id": "synthetic-only",
        "joints": Json(Array::makei(count, i => "joint_\{i}")),
        "default_q": Json(Array::make(count, 0.0)),
        "scales": Json(Array::make(count, 0.1)),
      },
    },
    "source_spec": {
      "format": "moonrobo.native-tensor-actor-spec.v1",
      "observation_mode": "smc",
      "hist": 1,
      "goal_frames": 1,
    },
    "physical_action_count": count,
  }
  @actor.Bundle::parse(Json(spec), robot)
}

///|
fn calibration(count : Int32) -> @sdk_e1_policy.Calibration {
  {
    format: "moonrobo.e1-sdk-calibration.v1",
    profile_id: "synthetic-only",
    axes: Array::makei(count, index => {
      actor_joint: "joint_\{index}",
      sdk_joint: "slot_\{23 - index}",
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
    fixed: if count == 23 {
      [
        {
          sdk_joint: "slot_0",
          motor_id: 100,
          position: 100.0,
          velocity: 10.0,
          torque: 20.0,
          kp: 30.0,
          kd: 40.0,
        },
      ]
    } else {
      []
    },
  }
}

///|
fn resolve(name : String) -> Int32 raise {
  guard name.strip_prefix("slot_") is Some(number) else {
    fail("unknown synthetic slot")
  }
  @string.parse_int(number)
}

///|
test "23 and 24 physical axes map by name sign and zero into complete SDK frames" {
  for count in [23, 24] {
    let bundle = fixture(count)
    let mapping = @sdk_e1_policy.Mapping::new(
      bundle,
      calibration(count),
      resolve~,
    )
    let actions = Array::makei(29, i => (i + 1).to_double())
    let commands = mapping.commands(actions[:])
    assert_eq(commands.length(), 24)
    for i in 0..<count {
      let command = commands[23 - i]
      let direction = if i % 2 == 0 { -1.0 } else { 1.0 }
      assert_true(
        (command.position - (0.25 + direction * 0.1 * (i + 1).to_double())).abs() <
        1.0e-12,
      )
      assert_eq(command.velocity, 0.0)
      assert_eq(command.torque, 0.0)
      assert_eq(command.kp, (10 + i).to_double())
      assert_eq(command.kd, (1 + i).to_double())
    }
    if count == 23 {
      let fixed = commands[0]
      assert_eq(
        (fixed.position, fixed.velocity, fixed.torque, fixed.kp, fixed.kd),
        (100.0, 10.0, 20.0, 30.0, 40.0),
      )
    }
  }
}

///|
test "mapping rejects incomplete and ambiguous calibration before any command exists" {
  let bundle = fixture(23)
  let original = calibration(23)
  let bad_axes = original.axes.copy()
  bad_axes[1] = { ..bad_axes[1], actor_joint: bad_axes[0].actor_joint, }
  let bad_slots = original.axes.copy()
  bad_slots[1] = { ..bad_slots[1], sdk_joint: bad_slots[0].sdk_joint, }
  let bad_direction = original.axes.copy()
  bad_direction[0] = { ..bad_direction[0], direction: 0.0, }
  let bad_gain = original.axes.copy()
  bad_gain[0] = { ..bad_gain[0], kp: -1.0, }
  for
    invalid in [
      { ..original, profile_id: "another-robot", },
      { ..original, fixed: [], },
      { ..original, axes: bad_axes, },
      { ..original, axes: bad_slots, },
      { ..original, axes: bad_direction, },
      { ..original, axes: bad_gain, },
    ] {
    try @sdk_e1_policy.Mapping::new(bundle, invalid, resolve~) catch {
      _ => ()
    } noraise {
      _ => fail("invalid calibration accepted")
    }
  }
  try @sdk_e1_policy.Mapping::new(bundle, original, resolve=_ => 24) catch {
    _ => ()
  } noraise {
    _ => fail("invalid SDK slot accepted")
  }
}

///|
test "decoded joint values and applied-command feedback preserve sign zero and mask" {
  let bundle = fixture(23)
  let mapping = @sdk_e1_policy.Mapping::new(bundle, calibration(23), resolve~)
  let actions = Array::makei(29, i => {
    if i < 23 {
      (i + 1).to_double() * 0.1
    } else {
      0.0
    }
  })
  let commands = mapping.commands(actions[:])
  let recovered = mapping.actions_for_commands(commands[:])
  for i in 0..<29 {
    assert_true((recovered[i] - actions[i]).abs() < 1.0e-12)
  }
  let ids = Array::makei(24, i => 100 + i)
  let pos = commands.map(m => m.position)
  let vel = Array::makei(24, i => i.to_double() * 0.01)
  let errors = Array::make(24, 0)
  let (q, qd) = mapping.joint_values(ids[:], pos[:], vel[:], errors[:])
  for i in 0..<23 {
    assert_true((q[i] - 0.1 * actions[i]).abs() < 1.0e-12)
    assert_eq(qd[i], (if i % 2 == 0 { -1.0 } else { 1.0 }) * vel[23 - i])
  }
  ids[3] = 99
  try mapping.joint_values(ids[:], pos[:], vel[:], errors[:]) catch {
    _ => ()
  } noraise {
    _ => fail("incorrect packet motor ID accepted")
  }
  ids[3] = 103
  errors[3] = 1
  try mapping.joint_values(ids[:], pos[:], vel[:], errors[:]) catch {
    _ => ()
  } noraise {
    _ => fail("motor error accepted")
  }
  try mapping.actions_for_commands(commands[:23]) catch {
    _ => ()
  } noraise {
    _ => fail("incomplete applied command accepted")
  }
}
