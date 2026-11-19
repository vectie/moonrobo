///|
test "registry summary uses all trials and preserves arithmetic mean semantics" {
  let trials : Array[Json] = [
    { "failed": false, "simulated_seconds": 30.0, "joint_rmse_rad": 0.1 },
    { "failed": true, "simulated_seconds": 10.0, "joint_rmse_rad": 0.3 },
  ]
  assert_eq(@learning_registry.trial_summary(trials), {
    "trials": 2,
    "falls": 1,
    "mean_survival_s": 20.0,
    "mean_joint_rmse_rad": 0.2,
  })
  assert_true((try? @learning_registry.trial_summary([])) is Err(_))
}
