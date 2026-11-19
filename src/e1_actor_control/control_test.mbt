///|
fn fixture() -> (@actor.Actor, @policy.Mapping) raise {
  let spec : @portable.Spec = {
    format: "lunakine.elu-actor.v1",
    history_frames: 2,
    observation_width: 99,
    encoder: [73, 32],
    decoder: [230, 29],
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
        "id": "synthetic-control",
        "joints": Json(Array::makei(23, i => "joint_\{i}")),
        "default_q": Json(Array::make(23, 0.0)),
        "scales": Json(Array::make(23, 1.0)),
      },
    },
    "source_spec": {
      "format": "moonrobo.native-tensor-actor-spec.v1",
      "observation_mode": "smc",
      "hist": 2,
      "goal_frames": 1,
    },
    "physical_action_count": 23,
  }
  let bundle = @actor.Bundle::parse(Json(spec), robot)
  let calibration : @policy.Calibration = {
    format: "moonrobo.e1-sdk-calibration.v1",
    profile_id: bundle.profile_id(),
    axes: Array::makei(23, i => {
      actor_joint: "joint_\{i}",
      sdk_joint: "slot_\{i}",
      motor_id: i,
      direction: 1.0,
      zero: 0.0,
      kp: 1.0,
      kd: 0.1,
    }),
    fixed: [
      {
        sdk_joint: "extra",
        motor_id: 23,
        position: 0.75,
        velocity: 0.0,
        torque: 0.0,
        kp: 1.0,
        kd: 0.1,
      },
    ],
  }
  let mapping = @policy.Mapping::new(bundle, calibration, resolve=name => {
    if name == "extra" {
      23
    } else {
      @string.parse_int(name.strip_prefix("slot_").unwrap())
    }
  })
  let parameters = Array::make(spec.parameter_count(), 0.0)
  for i in (parameters.length() - 29)..<parameters.length() {
    parameters[i] = 1.0
  }
  (
    @actor.Actor::reference(
      bundle,
      @portable.encode_parameters(parameters[:])[:],
    ),
    mapping,
  )
}

///|
fn supervisor(now : Int64) -> @skills.Supervisor raise {
  let result = @skills.Supervisor::new("control", [
    {
      id: "one",
      description: "software only",
      reference_id: "frames",
      maximum_duration_ms: 1000,
      parameters: [],
    },
  ])
  accept(result, "one", 0L, now)
  result
}

///|
fn accept(
  s : @skills.Supervisor,
  id : String,
  sequence : Int64,
  now : Int64,
) -> Unit raise {
  ignore(
    s.accept(
      {
        request_id: id,
        sequence,
        catalog_id: "control",
        context_version: s.version(),
        expires_at_ms: now + 1000L,
        proposal: { skill_id: "one", parameters: Map([]), },
      },
      now,
    ),
  )
}

///|
fn reference(complete~ : Bool = false) -> @e1_actor_control.Reference {
  {
    goals: Array::make(73, 0.0),
    body_to_world: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
    complete,
  }
}

///|
test "receipt age capture work and rounding all count before mapped publication" {
  for budget in [110L, 111L] {
    let (actor, mapping) = fixture()
    defer (actor.close() catch { _ => () })
    let clock = Ref(100L)
    let s = supervisor(clock.val)
    let writes = Ref(0)
    let stops = Ref(0)
    let sensor = @e1_actor_control.Sensor::new(
      profile_id=actor.bundle().profile_id(),
      clock=() => clock.val,
      capture=(_, _) => {
        clock.val = 150L
        { observation: Array::make(99, 0.0), receipt_age_ms: 60L, }
      },
    )
    let runner = @e1_actor_control.new_runner(
      s,
      actor,
      mapping,
      sensor,
      reference=(_, _, _) => reference(),
      maximum_sensor_age_ms=budget,
      publish=commands => {
        assert_eq(commands.length(), 24)
        assert_eq(commands[0].position, 1.0)
        assert_eq(commands[23].position, 0.75)
        writes.val += 1
      },
      stop=() => stops.val += 1,
    )
    // Conservatively received at100-60-1=39; publication at150 is111ms old.
    if budget == 111L {
      assert_true(runner.tick() is Action(_))
      assert_eq((writes.val, stops.val), (1, 0))
    } else {
      try runner.tick() catch {
        _ => ()
      } noraise {
        _ => fail("capture work made old input appear fresh")
      }
      assert_eq((writes.val, stops.val), (0, 1))
      assert_true(s.snapshot(clock.val) is Some({ state: Failed, .. }))
    }
  }
}

///|
test "completion and a new task still capture sensors and reset previous actions" {
  let (actor, mapping) = fixture()
  defer (actor.close() catch { _ => () })
  let clock = Ref(100L)
  let s = supervisor(clock.val)
  let previous_values : Array[Double] = []
  let writes = Ref(0)
  let stops = Ref(0)
  let sensor = @e1_actor_control.Sensor::new(
    profile_id=actor.bundle().profile_id(),
    clock=() => clock.val,
    capture=(previous, _) => {
      previous_values.push(previous[0])
      { observation: Array::make(99, 0.0), receipt_age_ms: 0L, }
    },
  )
  let runner = @e1_actor_control.new_runner(
    s,
    actor,
    mapping,
    sensor,
    reference=(_, step, _) => reference(complete=step == 2),
    publish=_ => writes.val += 1,
    stop=() => stops.val += 1,
  )
  ignore(runner.tick())
  clock.val = 120L
  ignore(runner.tick())
  clock.val = 140L
  assert_true(runner.tick() is Stopped)
  assert_true(s.snapshot(clock.val) is Some({ state: Completed, .. }))
  accept(s, "two", 1L, 160L)
  clock.val = 160L
  ignore(runner.tick())
  assert_eq(previous_values, [0.0, 1.0, 1.0, 0.0])
  assert_eq((writes.val, stops.val), (3, 1))
}

///|
suberror CaptureFailure {
  Original
}

///|
test "capture failures negative age rollback and stale completion never publish" {
  for mode in ["failure", "negative", "rollback", "stale-complete"] {
    let (actor, mapping) = fixture()
    defer (actor.close() catch { _ => () })
    let clock = Ref(1000L)
    let s = supervisor(clock.val)
    let stops = Ref(0)
    let sensor = @e1_actor_control.Sensor::new(
      profile_id=actor.bundle().profile_id(),
      clock=() => clock.val,
      capture=(_, _) => {
        if mode == "failure" {
          raise CaptureFailure::Original
        }
        if mode == "rollback" {
          clock.val = 999L
        }
        {
          observation: Array::make(99, 0.0),
          receipt_age_ms: if mode == "negative" {
            -1L
          } else {
            200L
          },
        }
      },
    )
    let runner = @e1_actor_control.new_runner(
      s,
      actor,
      mapping,
      sensor,
      reference=(_, _, _) => reference(complete=mode == "stale-complete"),
      publish=_ => fail("invalid capture reached publication"),
      stop=() => stops.val += 1,
    )
    try runner.tick() catch {
      error =>
        if mode == "failure" {
          assert_true(error is CaptureFailure::Original)
        }
    } noraise {
      _ => fail("invalid capture accepted")
    }
    assert_eq(stops.val, 1)
    assert_true(s.snapshot(1000L) is Some({ state: Failed, .. }))
  }
}

///|
test "mismatched sensor profile fails before capture or publication" {
  let (actor, mapping) = fixture()
  defer (actor.close() catch { _ => () })
  let sensor = @e1_actor_control.Sensor::new(
    profile_id="other",
    clock=() => 100L,
    capture=(_, _) => fail("mismatched sensor captured"),
  )
  try
    @e1_actor_control.new_runner(
      supervisor(100L),
      actor,
      mapping,
      sensor,
      reference=(_, _, _) => reference(),
      publish=_ => fail("mismatched profile published"),
      stop=() => (),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("mismatched control profile accepted")
  }
}
