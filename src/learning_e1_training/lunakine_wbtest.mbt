///|
async test "portable E1 bundle and runtime adapter preserve the trained actor actions" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(library) &&
    @env.get_env_var("MOONROBO_E1_ACTOR") is Some(directory) else {
    println(
      "SKIP real E1 portable integration: set MOONROBO_TENSOR_LIBRARY and MOONROBO_E1_ACTOR",
    )
    return
  }
  let temporary = @fs.tmpdir(prefix="lunakine-e1-integration")
  defer @fs.rmdir(temporary, recursive=true)
  let bundle = temporary + "/bundle"
  ignore(export_lunakine(directory, library, bundle))
  let (source, metadata) = load_actor(directory, library)
  let portable = load_portable_reference(bundle)
  for sample in 0..<3 {
    let history = Array::makei(metadata.spec.hist, frame => {
      Array::makei(metadata.spec.mode().dim(), feature => {
        @math.sin((frame + feature + sample).to_double() * 0.07) * 0.1
      })
    })
    let goals = Array::makei(metadata.spec.goal_frames * 73, i => {
      @math.cos((i + sample).to_double() * 0.03) * 0.2
    })
    let expected = source.forward_embedded(history, goals)
    let actual = portable.forward_embedded(history, goals)
    assert_eq(actual.length(), 29)
    for i in 0..<29 {
      assert_true((actual[i] - expected[i]).abs() < 0.0001)
      if i >= metadata.identity.robot.joints.length() {
        assert_eq(actual[i], 0.0)
      }
    }
    assert_eq(
      portable.forward(history, goals).length(),
      metadata.identity.robot.joints.length(),
    )
  }
  let robot = metadata.identity.robot
  let tape : ActorReplay = {
    format: "moonrobo.actor-replay.v1",
    catalog: {
      catalog_id: "software-fixture",
      context_version: 0L,
      last_sequence: -1L,
      skills: [
        {
          id: "nominal",
          description: "synthetic calibrated frames; not a qualified physical skill",
          reference_id: "nominal-reference",
          maximum_duration_ms: 200,
          parameters: [],
        },
      ],
    },
    request: {
      request_id: "shadow-one",
      sequence: 0L,
      catalog_id: "software-fixture",
      context_version: 0L,
      expires_at_ms: 1000L,
      proposal: { skill_id: "nominal", parameters: Map([]), },
    },
    frames: {
      "nominal-reference": Array::makei(3, i => {
        captured_at_ms: 100L + i.to_int64() * 20L,
        observation: robot.observation(
          robot.default_q,
          Array::make(robot.joints.length(), 0.0),
          Array::make(robot.joints.length(), 0.0),
          [0.0, 0.0, 0.0],
          [0.0, 0.0, -1.0],
          @aligned.mat_to_6d(@aligned.identity()),
        ),
        goals: Array::make(metadata.spec.goal_frames * 73, 0.0),
      }),
    },
  }
  let expected_report = replay_actor(source, tape)
  let actual_report = replay_actor(portable, tape)
  guard actual_report
    is {
      "published": False,
      "frames": Array(actual_rows),
      "execution": execution_json,
      ..
    } &&
    expected_report is { "frames": Array(expected_rows), .. } else {
    fail("shadow runner did not complete")
  }
  let execution : @skills.Execution = @json.from_json(execution_json)
  assert_true(execution.state is Completed)
  assert_eq(actual_rows.length(), 3)
  for i, row in actual_rows {
    guard row is { "actions": a, .. } &&
      expected_rows[i] is { "actions": e, .. } else {
      fail("missing shadow actions")
    }
    let actual : Array[Double] = @json.from_json(a)
    let expected : Array[Double] = @json.from_json(e)
    for j in 0..<actual.length() {
      assert_true((actual[j] - expected[j]).abs() < 0.001)
    }
  }
  portable.close()
  source.close()
}
