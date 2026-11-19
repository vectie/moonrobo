///|
test "original registry baseline selects configured method within matching seed" {
  let initial : Json = { "marker": "prior" }
  let run = (method : String, seed : Int32) => {
    (
      {
        "method": method,
        "seed": seed,
        "cycles": [1, 2, 3, 4, 5, 6],
        "trials": [],
        "marker": seed,
      } : Json)
  }
  let report : Json = {
    "initial": initial,
    "config": { "reused_baseline_method": "replay-prefix-extended" },
    "runs": [
      run("replay-prefix-extended", 0),
      run("replay-prefix-extended", 1),
      run("prefix-only", 1),
    ],
  }
  let (selected, _) = comparison_baseline(report, "candidate", 1)
  assert_eq(selected, run("replay-prefix-extended", 1))
  let (prior, _) = comparison_baseline(report, "replay-prefix-extended", 1)
  assert_eq(prior, initial)
  let fallback : Json = {
    "initial": initial,
    "config": {},
    "runs": [run("prefix-only", 0), run("prefix-only", 1)],
  }
  let (default, role) = comparison_baseline(fallback, "candidate", 1)
  assert_eq(default, run("prefix-only", 1))
  assert_eq(role, "Fixed reset-only trained policy with the same training seed")
}

///|
test "original registry truncated replay retains full planned suffix and archived states" {
  let f = contract_fixture(seed=17U)
  let origin = 4
  let count = 6
  let selected = f.episode.steps[origin:origin + count].to_owned()
  let episode = { ..f.episode, steps: selected, }
  let arrays = episode_arrays(episode)
  let before = arrays["next_state"].values.copy()
  let record : Json = { "context": [1.0, 1.0], "origin_step": origin }
  let trial : Json = {
    "failed": true,
    "requested_seconds": 0.32,
    "simulated_seconds": 0.12,
  }
  let result = trace_trial(
    f.runtime,
    f.archive,
    record,
    trial,
    arrays,
    true,
    0.02,
  )
  let replay = json_array(json_field(result, "replay"))
  let planned = json_array(json_field(result, "reference_replay"))
  assert_eq(replay.length(), count)
  assert_eq(planned.length(), f.schedule.length - origin)
  assert_eq(json_number(json_field(replay[0], "time_s")), 0.02)
  assert_eq(json_number(json_field(planned.last().unwrap(), "time_s")), 0.32)
  assert_eq(json_number(json_field(result, "reference_start_time_s")), 0.08)
  assert_eq(json_field(result, "end_reason"), "fall".to_json())
  for frame in replay {
    for
      metric in [
        "root_position_error_m", "body_position_error_m", "joint_rmse_rad",
      ] {
      assert_true(json_number(json_field(frame, metric)).abs() < 1.0e-12)
    }
  }
  assert_eq(arrays["next_state"].values, before)
}

///|
test "original learning reused baseline archive includes only shared and requested method episodes" {
  let report : Json = {
    "physical_records": [
      { "episode_id": "initial", "role": "initial" },
      { "episode_id": "common", "role": "common-first-collection" },
      { "episode_id": "diagnostic", "role": "model-diagnostic" },
      { "episode_id": "other", "role": "training" },
    ],
    "runs": [
      {
        "method": "selected",
        "trials": [{ "episode_id": "selected-final" }],
        "cycles": [{ "training_episode_ids": ["selected-train"] }],
      },
      {
        "method": "other",
        "trials": [{ "episode_id": "other-final" }],
        "cycles": [{ "training_episode_ids": ["other-train"] }],
      },
    ],
  }
  let ids = baseline_record_ids(report, "selected")
  assert_eq(ids.length(), 5)
  for
    id in [
      "initial", "common", "diagnostic", "selected-final", "selected-train",
    ] {
    assert_true(ids.contains(id))
  }
  for id in ["other", "other-final", "other-train"] {
    assert_false(ids.contains(id))
  }
}
