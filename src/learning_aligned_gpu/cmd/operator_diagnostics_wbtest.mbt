///|
test "operator diagnostic opt-in is isolated from training and rejects ambiguous flags" {
  assert_eq(operator_diagnostic_request(["tool", "train"]), (false, false))
  assert_eq(operator_diagnostic_request(["tool", "preflight"]), (false, false))
  assert_eq(
    operator_diagnostic_request(["tool", "train", "--operator-diagnostics"]),
    (true, false),
  )
  assert_eq(
    operator_diagnostic_request([
      "tool", "diagnose-operators", "--preflight-only",
    ]),
    (true, true),
  )
  for
    args in [
      ["tool", "train", "--preflight-only"],
      ["tool", "evaluate", "--operator-diagnostics"],
      ["tool", "train", "--operator-diagnostics=1"],
      ["tool", "train", "--operator-diagnostics", "--operator-diagnostics"],
      ["tool", "diagnose-operators", "--resume", "checkpoint"],
      ["tool", "diagnose-operators", "--distributed"],
      ["tool", "diagnose-operators", "--execution-profile"],
    ] {
    try operator_diagnostic_request(args) catch {
      _ => ()
    } noraise {
      _ => fail("ambiguous diagnostic request accepted")
    }
  }
}

///|
test "diagnostic CLI settings reach real phase admission with exactly one four GiB reserve" {
  // Fixed G2 six-switch paper4096/micro512 workload. This traverses the same
  // settings -> optimization_memory_extra -> estimate_memory path as the CLI;
  // a hand-written admission extra map would miss a malformed CLI reserve key.
  let config : Json = {
    "capacity_profile": "paper-4096",
    "memory_admission_percent": 80,
    "device": "cuda:0",
    "backend": "isaac",
    "precision": "float32",
    "amp": "none",
    "allow_tf32": true,
    "reference_storage": "mmap",
    "num_envs": 256,
    "buffer_steps": 1000,
    "wm_batch": 2048,
    "pi_batch": 4096,
    "wm_microbatch": 0,
    "pi_microbatch": 512,
    "wm_hidden": [2048, 2048, 2048],
    "pi_hidden": [2048, 1024, 512, 256],
    "critic_hidden": [256, 128],
    "observation_mode": "smc",
    "hist": 10,
    "goal_frames": 10,
    "horizon": 32,
    "wm_window": 8,
    "wm_batches": 10,
    "warmup_steps": 64,
    "wm_only_iters": 20,
    "iterations": 41,
    "checkpoint_every": 60,
    "critic_epochs": 5,
    "critic_minibatches": 4,
    "lr_decay_iters": 250000,
    "serial_optimizer_save_workspace": true,
    "max_motion_sampler_bins": 9000,
    "reuse_geometry": true,
    "body_orientation_batched": true,
    "resident_reference_cache": true,
    "resident_reference_max_mib": 1376,
    "adam_checked_norm": true,
    "defer_scalar_metrics": true,
    "world_staging_batch": true,
    "world_staging_max_mib": 128,
    "layer_norm_mode": "expanded",
    "critic_cuda_graph": false,
    "noise_staging_batch": false,
    "actor_norm_snapshot": false,
  }
  let regular_args = [
    "aligned-gpu", "preflight", "--checkpoint-format", "stream-v2", "--cuda-memory-telemetry",
  ]
  let regular = settings(config, regular_args)
  let diagnostic = settings(config, [
    "aligned-gpu", "diagnose-operators", "--preflight-only", "--checkpoint-format",
    "stream-v2", "--cuda-memory-telemetry", "--iterations", "41",
  ])
  let full_diagnostic = settings(
    config,
    regular_args + ["--operator-diagnostics"],
  )
  let regular_extra = optimization_memory_extra(regular)
  let diagnostic_extra = optimization_memory_extra(diagnostic)
  assert_true(!regular_extra.contains("execution_operator_diagnostics"))
  assert_true(!diagnostic_extra.contains("diagnostic_operator_timeline"))
  assert_eq(diagnostic_extra.length(), regular_extra.length() + 1)
  assert_eq(diagnostic_extra["execution_operator_diagnostics"], 4294967296L)
  for key, bytes in regular_extra {
    assert_eq(diagnostic_extra[key], bytes)
  }
  let physical : PhysicsPreflight = {
    manifest_sha256: "5125dd55906ec0e5ffc9669007f60266137ee866c3b528574f6a11e6fa325c9b",
    bundle_bytes: 230465552L,
    shared_region_bytes: 47905609L,
    largest_file_bytes: 1L,
    manifest_bytes: 106611L,
    manifest_identity: Json::null(),
  }
  let host = 107374182400L
  let cuda = Some(100000000000L)
  let baseline = estimate_memory(
    regular,
    host,
    cuda,
    physical~,
    include_restore=false,
    motion_manifest_bytes=38601L,
  ).phase_plan.unwrap()
  let full = estimate_memory(
    full_diagnostic,
    host,
    cuda,
    physical~,
    include_restore=false,
    motion_manifest_bytes=38601L,
  ).phase_plan.unwrap()
  let initial = estimate_memory(
    diagnostic,
    host,
    cuda,
    physical~,
    include_restore=false,
    motion_manifest_bytes=38601L,
  )
  let known = estimate_memory(
    diagnostic,
    host,
    cuda,
    physical~,
    include_restore=false,
    sampler_bins=8842,
    motion_manifest_bytes=38601L,
  )
  let projected = initial.phase_plan.unwrap()
  assert_eq(baseline.phases.length(), 5)
  assert_eq(full.phases.length(), 5)
  assert_eq(projected.phases.length(), 3)
  assert_eq(projected.counts["execution_operator_diagnostics"], 4294967296L)
  assert_eq(projected.peak_bytes, 60455485328L)
  let decision = initial.admission_decision.unwrap()
  assert_eq(decision.required_remaining_bytes, 77635354512L)
  assert_eq(decision.admission_percent, 80)
  assert_eq(decision.minimum_free_reserve_bytes, 17179869184L)
  assert_true(known.peak_bytes <= initial.peak_bytes)
  for i, phase in full.phases {
    assert_eq(
      phase.envelope_bytes,
      baseline.phases[i].envelope_bytes + 4294967296L,
    )
    assert_eq(phase.components["execution_operator_diagnostics"], 4294967296L)
    for name, bytes in baseline.phases[i].components {
      assert_eq(phase.components[name], bytes)
    }
  }
  for i, phase in projected.phases {
    assert_eq(Json(phase), Json(full.phases[i]))
  }
  for phase in known.phase_plan.unwrap().phases {
    assert_eq(phase.components["execution_operator_diagnostics"], 4294967296L)
  }
  try projected.with_execution_reserve(diagnostic_extra) catch {
    _ => ()
  } noraise {
    _ => fail("duplicate diagnostic reserve accepted")
  }
  // The real CLI estimator still rejects one byte below unchanged admission.
  let required = decision.required_remaining_bytes
  try
    estimate_memory(
      diagnostic,
      required,
      Some(required - 1L),
      physical~,
      include_restore=false,
      motion_manifest_bytes=38601L,
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("diagnostic CLI bypassed original headroom guard")
  }
}
