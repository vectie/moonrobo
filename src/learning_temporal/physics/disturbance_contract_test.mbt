///|
/// Port of test_temporal_disturbance.py, including independent teacher instances and separate teacher labels vs noisy executed controls.
test "noisy labeled collection keeps actual controls and resets per-episode teacher memory" {
  let runtime = native_fixture()
  let actor = native_actor(runtime, 10, 10)
  let counts : Array[Ref[Int32]] = []
  let factory = fn() -> (Array[Double], Array[Double]) -> Array[Double] {
    let count = Ref::new(0)
    counts.push(count)
    fn(_obs, goal) {
      count.val += 1
      goal.map(fn(x) { x + 0.2 })
    }
  }
  let configured : ScheduledCase = {
    case: fixture_case(),
    offset: None,
    schedule: None,
  }
  let batch = collect_labeled(
    runtime,
    actor,
    [configured],
    [3, 4],
    5U,
    0.03,
    0.2,
    0.02,
    None,
    teacher_factory=factory,
  )
  assert_eq(counts.map(fn(count) { count.val }), [10, 10])
  assert_eq(batch.trials.length(), 2)
  for i, episode in batch.episodes {
    assert_eq(batch.teacher_targets[i], Array::makei(10, fn(_) { [0.2] }))
    assert_eq(episode.steps.length(), 10)
    assert_true(episode.steps.any(fn(s) { s.applied_action[0] != 0.0 }))
    assert_true(episode.steps.any(fn(s) { s.applied_action != [0.2] }))
    let points = episode_points(episode, 10, 10, 0.02, fn(_) { [0.0] })
    assert_eq(points[0].history[9][8], 0.0)
    for j in 1..<points.length() {
      assert_eq(points[j].history[9][8], episode.steps[j - 1].applied_action[0])
    }
  }
  let held_out : ScheduledCase = {
    ..configured,
    case: { ..configured.case, split: "validation", },
  }
  let rejected : LabeledCollection? = Some(
    collect_labeled(
      runtime,
      actor,
      [held_out],
      [3],
      5U,
      0.03,
      0.2,
      0.02,
      None,
      teacher_factory=factory,
    ),
  ) catch {
    _ => None
  }
  assert_true(rejected.is_none())
}
