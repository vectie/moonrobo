///|
async test "opt-in actual production critic trace against frozen CUDA actor-1" {
  guard @env.get_env_var("MOONROBO_CRITIC_TRACE_MODE") is Some(mode) else {
    println("SKIP opt-in actual critic trace; no GPU execution")
    return
  }
  guard mode == "full" || mode == "split" else {
    fail("trace MODE must be full or split")
  }
  guard @env.get_env_var("MOONROBO_CRITIC_TRACE_PROFILE") == Some("paper-cuda") &&
    @env.get_env_var("NVIDIA_TF32_OVERRIDE") == Some("0") &&
    @env.get_env_var("CUBLAS_WORKSPACE_CONFIG") == Some(":4096:8") else {
    fail(
      "trace requires explicit paper-cuda profile, TF32 override 0 and CUBLAS :4096:8",
    )
  }
  let root = @env.get_env_var("MOONROBO_CRITIC_TRACE_OUTPUT").unwrap_or("")
  let baseline = @env.get_env_var("MOONROBO_CRITIC_TRACE_BASELINE").unwrap_or(
    "",
  )
  for path in [root, baseline] {
    guard path.has_prefix("/") &&
      @fs.realpath(path) == path &&
      @fs.kind(path) is Directory else {
      fail(
        "trace output and frozen baseline must be existing canonical absolute directories",
      )
    }
  }
  let output = root + "/" + mode
  guard !@fs.exists(output) else { fail("trace refuses existing output mode") }
  let old_root = baseline + "/" + mode
  let old_run_path = old_root + "/run.json"
  let old_snapshot_path = old_root + "/actor-1/snapshot.json"
  let (old_run, run_sha) = trace_read_json(old_run_path)
  let (old_snapshot_json, snapshot_sha) = trace_read_json(old_snapshot_path)
  let expected_run_sha = if mode == "full" {
    "b929cb44c347fa20541fbb85ba860d824f8788af809167572d5c8f4e79c883fa"
  } else {
    "2b7a413c3baf0a7e556a380657c9a5974f37a9732a7df719c700f70034e0b2ff"
  }
  let expected_snapshot_sha = if mode == "full" {
    "ef463fadb7956b07830e3967eeea724da7fc044ef05caa3871dbe8e3165f0975"
  } else {
    "b4c1ada01755a40b24e6da1af632404fa6d4f2a1b81275df8fcf1f4d5c9aa1df"
  }
  guard run_sha == expected_run_sha && snapshot_sha == expected_snapshot_sha else {
    fail(
      "trace baseline differs from frozen native-microbatch-numeric-20261024-a metadata",
    )
  }
  guard old_run is Object(old_fields) &&
    old_fields["format"] == "moonrobo.microbatch-numerical-run.v1" &&
    old_fields["completed"] == true &&
    old_fields["profile"] == "paper-cuda" &&
    old_fields["mode"] == Json(mode) &&
    old_fields["seed"] == 1 &&
    old_fields["binary_sha256"] ==
    "83cc114a2b69065019fcb84affc9b7f65ecb137abf410e167b8d3d4cb3d1113a" else {
    fail("trace frozen run identity differs")
  }
  let library = @env.get_env_var("MOONROBO_TENSOR_LIBRARY").unwrap_or("")
  guard library.has_prefix("/") else {
    fail("trace needs absolute frozen tensor plugin path")
  }
  let plugin_sha = gate_file_sha(library)
  guard plugin_sha ==
    "a1176bb28ce4fb928006c7e5db20fbe1b693bcabab6d482e0f766a00ad802f1f" &&
    old_fields["plugin_sha256"] == Json(plugin_sha) else {
    fail("trace must use the unchanged frozen CUDA tensor plugin")
  }
  let old_snapshot : CriticTraceFrozen = @json.from_json(old_snapshot_json)
  @fs.mkdir(output)
  let backend = @tensor.Backend::open(library)
  let before = gate_memory(backend, 0)
  gate_memory_budget(before)
  gate_json(output + "/preflight.json", before)
  let config = {
    ..@aligned.LearnerConfig::default(),
    wm_batch: 4,
    policy_batch: 4,
    wm_batches: 1,
  }
  guard old_fields["config"] == config.to_json() else {
    fail("trace config differs from frozen gate")
  }
  let chunk = if mode == "full" { 0 } else { 2 }
  let learner = Learner::new(
    backend,
    @geometry.Context::new(backend, micro_context(backend).kin, 0),
    config~,
    cuda_device=0,
    seed=1U,
    world_microbatch=chunk,
    actor_microbatch=chunk,
  )
  let (world, policy) = gate_batches(backend, 0, 5)
  let identity = gate_input_identity(backend, world, policy)
  let initial = learner.shared_state_digest()
  guard old_fields["input_identity"] == identity &&
    old_fields["initial_shared_state"] == initial.to_json() else {
    fail("trace input or initial learner identity differs")
  }
  trace_test_prepare(learner, world, policy)
  // No extra probe is replayed. Exact same-mode final record hashes below must
  // establish that omitting the old non-mutating probe did not alter the update.
  let trace = CriticTrace::new(256)
  let metric = learner.update_policy_impl(
    policy,
    train_critic=true,
    trace=Some(trace),
  )
  let trace_report = trace_write_records(output, trace)
  let final = trace_final_digest(learner, metric)
  let differences = trace_compare_frozen(final, old_snapshot)
  gate_json(output + "/actor-1-final-summary.json", final.to_json())
  gate_json(output + "/run.json", {
    "format": "moonrobo.actual-critic-trace-run.v1",
    "completed": true,
    "mode": Json(mode),
    "profile": "paper-cuda",
    "config": config.to_json(),
    "execution": learner.batch_execution().to_json(),
    "input_identity": identity,
    "initial_shared_state": initial.to_json(),
    "plugin_sha256": Json(plugin_sha),
    "binary_sha256": Json(gate_file_sha("/proc/self/exe")),
    "baseline_run_sha256": Json(run_sha),
    "baseline_actor1_snapshot_sha256": Json(snapshot_sha),
    "same_mode_frozen_actor1_all_record_sha256_equal": Json(
      differences.is_empty(),
    ),
    "frozen_record_differences": Json(differences),
    "world_optimizer_updates": 2,
    "actor_optimizer_updates": 1,
    "critic_optimizer_updates": 20,
    "extra_probe_rollouts": 0,
    "trace": trace_report,
    "final_memory": gate_memory(backend, 0),
    "original_full_split_gate_passed": false,
    "original_absolute_tolerance": 0.000002,
    "original_relative_tolerance": 0.0002,
    "baseline_sidecar_payloads_revalidated": false,
    "memory_saving_claimed": false,
  })
  guard differences.is_empty() else {
    fail(
      "trace captured, but same-mode frozen actor-1 changed; inspect run.json before causal attribution",
    )
  }
  println(
    "actual \{mode} critic trace complete; all frozen actor-1 record hashes match",
  )
}
