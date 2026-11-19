///|
/// Dynamic restore/history/command-phase contract from test_temporal_probe.py, with the versioned one-hinge scene and deterministic declared command schedule.
test "restored temporal control preserves integration history command phase and original end" {
  let runtime = native_fixture()
  let actor = native_actor(runtime, 3, 2)
  let rng = @numeric.Rng::new(2U)
  let last = actor.temporal.adapter.parameters.length() - 9
  for i in last..<(actor.temporal.adapter.parameters.length() - 1) {
    actor.temporal.adapter.parameters[i] = 0.3 * (2.0 * rng.uniform() - 1.0)
  }
  let raw_case : Json = {
    "id": "sines",
    "family": "training-family",
    "split": "train",
    "motion": "random_joint_sines",
    "keyframe": "home",
    "friction": 1.0,
    "goal_offset_rad": { "lower": 0.1, "waist": 0.1, "upper": 0.1 },
  }
  let case : @native_physics.Case = @json.from_json(raw_case)
  let (offset, schedule) = @balance_native.sample_reference(
    runtime, raw_case, 3,
  )
  let frames : Array[Array[Double]] = []
  let mut nominal : Array[Double] = []
  let mut phase = 0
  let origins : Map[Int32, Origin] = {}
  let predict = fn(obs : Array[Double], goal : Array[Double]) {
    if frames.is_empty() {
      nominal = [obs[0]]
      for _ in 0..<3 {
        frames.push(obs.copy())
      }
    } else {
      frames.remove(0) |> ignore
      frames.push(obs.copy())
    }
    let future = Array::makei(2, fn(i) {
      try! runtime.reference(
        nominal,
        case.motion,
        (phase + i + 1).to_double() * 0.02,
        offset?,
        schedule?,
      )
    })
    phase += 1
    actor.predict(frames, goal, future)
  }
  let trace = fn(step : Int32, _action : Array[Double], _goal : Array[Double]) {
    if [0, 2, 4].contains(step) {
      let goals = Array::makei(10 - step + 2, fn(i) {
        try! runtime.reference(
          nominal,
          case.motion,
          (step + i).to_double() * 0.02,
          offset?,
          schedule?,
        )
      })
      origins[step] = {
        integration: runtime.integration(),
        state: runtime.state(),
        history: frames.map(fn(row) { row.copy() }),
        goals,
        context: [1.0, 1.0],
        remaining_steps: 10 - step,
      }
    }
  }
  let reset_rng = @numeric.Rng::new(3U)
  let (episode, _) = runtime.rollout(
    case,
    3,
    "policy",
    0.2,
    0.02,
    fn() { reset_rng.normal() },
    policy=predict,
    offset?,
    schedule?,
    trace~,
  )
  assert_eq(origins.length(), 3)
  let original_state = runtime.state()
  let original_integration = runtime.integration()
  for (start, origin) in origins {
    let actual = physical_return(runtime, origin, actor, 0.02, 0.99, 1.0)
    assert_eq(actual.steps, 10 - start)
    assert_false(actual.failed)
    assert_eq(runtime.state(), original_state)
    assert_eq(runtime.integration(), original_integration)
    for i in 0..<actual.steps {
      close_native(
        actual.states[i],
        episode.steps[start + i].next_state,
        1.0e-12,
      )
      close_native(
        actual.actions[i],
        episode.steps[start + i].applied_action,
        1.0e-12,
      )
    }
  }
  let origin = origins[4]
  let changed_history = origin.history.map(fn(row) { row.copy() })
  changed_history[0] = Array::make(9, 10.0)
  changed_history[1] = Array::make(9, 10.0)
  let changed : Origin = { ..origin, history: changed_history, }
  let new_actions = physical_return(runtime, changed, actor, 0.02, 0.99, 1.0).actions
  let old_actions = physical_return(runtime, origin, actor, 0.02, 0.99, 1.0).actions
  assert_true(
    Array::makei(new_actions.length(), fn(i) {
      (new_actions[i][0] - old_actions[i][0]).abs()
    }).any(fn(x) { x > 1.0e-9 }),
  )
}
