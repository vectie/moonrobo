///|
test "registry summary preserves arithmetic mean of per-trial RMSE" {
  let summary = @learning_reference.trial_summary([
    { "failed": false, "simulated_seconds": 10.0, "joint_rmse_rad": 1.0 },
    { "failed": true, "simulated_seconds": 2.0, "joint_rmse_rad": 3.0 },
  ])
  json_inspect(summary, content={
    "trials": 2,
    "falls": 1,
    "mean_survival_s": 6,
    "mean_joint_rmse_rad": 2,
  })
}

///|
test "learning registry baseline follows configured method and seed" {
  let initial : Json = { "trials": [], "role": "initial" }
  let report : Json = {
    "config": { "reused_baseline_method": "replay-prefix-extended" },
    "initial": initial,
    "runs": [
      {
        "method": "replay-prefix-extended",
        "seed": 7,
        "cycles": [1, 2, 3, 4, 5, 6],
        "trials": [],
      },
    ],
  }
  let (same, shared) = @learning_reference.comparison_baseline(
    report, "replay-prefix-extended", 7,
  )
  assert_eq(same, initial)
  assert_eq(shared, "Shared zero-output prior")
  let (_, role) = @learning_reference.comparison_baseline(
    report, "candidate", 7,
  )
  assert_eq(
    role, "Fixed six-cycle recent-FIFO trained policy with the same training seed",
  )
}
