///|
fn bundle() -> @actor.Bundle raise {
  let spec : @portable.Spec = {
    format: "lunakine.elu-actor.v1",
    history_frames: 1,
    observation_width: 99,
    encoder: [146, 32],
    decoder: [131, 29],
    observation_norm: {
      mean: Array::make(99, 0.0),
      variance: Array::make(99, 1.0),
      epsilon: 0.01,
    },
    goal_norm: {
      mean: Array::make(146, 0.0),
      variance: Array::make(146, 1.0),
      epsilon: 0.01,
    },
    action_mask: Array::makei(29, i => if i < 23 { 1.0 } else { 0.0 }),
  }
  @actor.Bundle::parse(Json(spec), {
    "format": "moonrobo.lunakine-e1.v1",
    "identity": {
      "robot": {
        "format": "moonrobo.e1-embedded-profile.v1",
        "id": "reference-fixture",
        "joints": Json(Array::makei(23, i => "joint_\{i}")),
        "default_q": Json(Array::make(23, 0.0)),
        "scales": Json(Array::make(23, 1.0)),
      },
    },
    "source_spec": {
      "format": "moonrobo.native-tensor-actor-spec.v1",
      "observation_mode": "smc",
      "hist": 1,
      "goal_frames": 2,
    },
    "physical_action_count": 23,
  })
}

///|
fn record() -> Json {
  {
    "format": "moonrobo.e1-actor-reference.v1",
    "profile_id": "reference-fixture",
    "joints": Json(Array::makei(23, i => "joint_\{i}")),
    "reference_id": "prepared",
    "control_dt_ms": 20,
    "goal_layout": "aligned.preview73.v1",
    "frames": Json(
      Array::makei(3, step => {
        let value : Json = {
          "goals": Json(
            Array::makei(146, i => step.to_double() + i.to_double() * 0.01),
          ),
          "body_to_world": [0.0, -1.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0],
        }
        value
      }),
    ),
  }
}

///|
fn execution() -> @skills.Execution {
  {
    request_id: "one",
    sequence: 0L,
    skill_id: "prepared-skill",
    reference_id: "prepared",
    parameters: Map([]),
    state: Running,
    accepted_at_ms: 100L,
    deadline_ms: 1100L,
    detail: "software",
  }
}

///|
test "prepared reference steps own their data and complete on the last state" {
  let clip = @e1_actor_reference.Clip::parse(bundle(), record())
  assert_eq(
    (clip.reference_id(), clip.frame_count(), clip.duration_ms()),
    ("prepared", 3, 40L),
  )
  let first = clip.frame(execution(), 0)
  assert_true(!first.complete)
  assert_eq(first.goals[145], 1.45)
  assert_eq(first.body_to_world, [0.0, -1.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0])
  first.goals[0] = 1000.0
  first.body_to_world[0] = 1000.0
  assert_eq(clip.frame(execution(), 0).goals[0], 0.0)
  assert_eq(clip.frame(execution(), 0).body_to_world[0], 0.0)
  assert_true(!clip.frame(execution(), 1).complete)
  assert_true(clip.frame(execution(), 2).complete)
  assert_eq(clip.frame(execution(), 100).goals[0], 2.0)
  assert_true(clip.frame(execution(), 100).complete)
}

///|
test "prepared reference rejects incompatible metadata geometry and goals" {
  let bundle = bundle()
  for
    pair in [
      ("format", Json("other")),
      ("profile_id", Json("other")),
      ("joints", Json(["wrong"])),
      ("reference_id", Json("")),
      ("control_dt_ms", Json(30)),
      ("goal_layout", Json("other")),
      ("frames", @json.parse("[]")),
    ] {
    let (field, replacement) = pair
    guard record() is Object(fields) else { fail("fixture record") }
    fields[field] = replacement
    try @e1_actor_reference.Clip::parse(bundle, Json(fields)) catch {
      _ => ()
    } noraise {
      _ => fail("incompatible reference contract accepted: " + field)
    }
  }
  for
    matrix in [
      [1.0],
      [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, -1.0],
      [1.0, 0.1, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
    ] {
    guard record() is Object(fields) else { fail("fixture record") }
    let frame : Json = {
      "goals": Json(Array::make(146, 0.0)),
      "body_to_world": Json(matrix),
    }
    fields["frames"] = Json([frame, frame])
    try @e1_actor_reference.Clip::parse(bundle, Json(fields)) catch {
      _ => ()
    } noraise {
      _ => fail("invalid reference rotation accepted")
    }
  }
  guard record() is Object(fields) else { fail("fixture record") }
  let frame : Json = {
    "goals": [0.0],
    "body_to_world": [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
  }
  fields["frames"] = Json([frame, frame])
  try @e1_actor_reference.Clip::parse(bundle, Json(fields)) catch {
    _ => ()
  } noraise {
    _ => fail("wrong goal width accepted")
  }
}

///|
test "prepared reference never silently ignores a different selection or parameters" {
  let clip = @e1_actor_reference.Clip::parse(bundle(), record())
  for
    task in [
      { ..execution(), reference_id: "other", },
      { ..execution(), parameters: { "speed": 1.0 }, },
    ] {
    try clip.frame(task, 0) catch {
      _ => ()
    } noraise {
      _ => fail("unsupported reference task accepted")
    }
  }
  try clip.frame(execution(), -1) catch {
    _ => ()
  } noraise {
    _ => fail("negative reference step accepted")
  }
}
