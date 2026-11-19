///|
/// Native replay contracts from test_full_body_reference.py, using a versioned toy scene instead of the optional Menagerie download. Pure frame/quality contracts are in reference_test.mbt.
fn recorded_reference(
  runtime : @native_physics.Runtime,
) -> NativeReference raise {
  let frames : Array[ReferenceFrame] = []
  let case : @native_physics.Case = {
    id: "stand",
    family: "procedural-stand",
    motion: "stand",
    keyframe: "home",
    split: "train",
    friction: 1.0,
  }
  let rng = @numeric.Rng::new(17U)
  let (episode, _) = runtime.rollout(
    case,
    17,
    "position",
    0.4,
    0.02,
    fn() { rng.normal() },
    trace=fn(i, _, _) {
      frames.push(try! capture_frame(runtime, i.to_double() * 0.02))
    },
  )
  frames.push(capture_frame(runtime, episode.steps.length().to_double() * 0.02))
  NativeReference::new(
    runtime,
    frames,
    episode.steps.map(fn(s) { s.applied_action }),
    episode.steps.map(fn(s) { s.observation }),
    0.02,
  )
}

///|
test "source control replay from nonzero origin evolves without state overwrites" {
  let runtime = @native_physics.Runtime::open(
    fixture_library(),
    "src/learning_balance/physics/testdata/replay.xml",
  )
  let reference = recorded_reference(runtime)
  let case : @native_physics.Case = {
    id: "stand",
    family: "procedural-stand",
    motion: "stand",
    keyframe: "home",
    split: "train",
    friction: 1.0,
  }
  let (episode, trial) = replay_reference(
    runtime, reference, case, 7, "source-setpoint",
  )
  assert_eq(episode.steps.length(), reference.controls.length() - 7)
  assert_false(episode.steps[episode.steps.length() - 1].terminated)
  assert_true(episode.steps[episode.steps.length() - 1].truncated)
  guard trial is Object(fields) else {
    fail("reference trial is not an object")
  }
  let maximum : Double = @json.from_json(fields["max_state_component_error"])
  assert_true(maximum < 1.0e-10)
  assert_eq(episode.steps[0].goal, reference.reference.goals[8])
}

///|
test "reference policy interface matches next joint positions and explicit tail mask" {
  let runtime = @native_physics.Runtime::open(
    fixture_library(),
    "src/learning_balance/physics/testdata/replay.xml",
  )
  let reference = recorded_reference(runtime)
  let case : @native_physics.Case = {
    id: "stand",
    family: "procedural-stand",
    motion: "stand",
    keyframe: "home",
    split: "train",
    friction: 1.0,
  }
  let previews : Array[Array[Bool]] = []
  let policy = fn(
    obs : Array[Double],
    current : Array[Double],
    future : Array[Array[Double]],
    valid : Array[Bool],
  ) -> Array[Double] {
    assert_eq(obs.length(), 9) catch {
      _ => abort("reference observation shape changed")
    }
    assert_eq(current.length(), reference.reference.goals[0].length()) catch {
      _ => abort("reference current shape changed")
    }
    assert_eq(future.length(), 10) catch {
      _ => abort("reference preview shape changed")
    }
    previews.push(valid)
    [future[0][0]]
  }
  let (actual, _) = replay_reference(
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
  assert_true(previews[0].all(fn(v) { v }))
  assert_eq(previews[previews.length() - 1].filter(fn(v) { v }).length(), 1)
  let altered = reference.controls.map(fn(row) { row.map(fn(x) { x + 100.0 }) })
  let changed = NativeReference::new(
    runtime,
    reference.frames,
    altered,
    reference.observations,
    reference.reference.dt,
  )
  assert_eq(changed.reference.goals, reference.reference.goals)
}
