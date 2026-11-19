///|
/// Port of test_balance_export.py. Forward/contact reconstruction must equal the captured replay and must never step the simulator.
test "recorded next-state reconstruction matches captured contact replay" {
  let runtime = @native_physics.Runtime::open(
    fixture_library(),
    "src/learning_balance/physics/testdata/replay.xml",
  )
  let case : @native_physics.Case = {
    id: "stand",
    family: "stand",
    motion: "stand",
    keyframe: "home",
    split: "train",
    friction: 0.7,
  }
  let rng = @numeric.Rng::new(7U)
  let (episode, trial) = runtime.rollout(case, 7, "position", 0.12, 0.02, fn() {
    rng.normal()
  })
  let actual = replay_from_recorded_states(runtime, episode, 0.02)
  assert_true(trial.replay.any(fn(row) { row.contacts > 0 }))
  assert_eq(actual.length(), trial.replay.length())
  for i, row in actual {
    let expected = trial.replay[i]
    assert_eq(row.contacts, expected.contacts)
    assert_true((row.time_s - expected.time_s).abs() < 1.0e-14)
    close_array(row.qpos, expected.qpos, 1.0e-14)
    close_array(row.target, expected.target, 1.0e-14)
    assert_true((row.root_height_m - expected.root_height_m).abs() < 1.0e-14)
    assert_true((row.upright_z - expected.upright_z).abs() < 1.0e-14)
  }
}
