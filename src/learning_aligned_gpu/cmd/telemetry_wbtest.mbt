///|
// Synthetic counters exercise diagnostic bookkeeping only, never GPU physics.
fn telemetry_fixture_stats(peak : Int64) -> @tensor.CudaMemoryStats {
  {
    device: 0,
    synchronized: true,
    allocated_current_bytes: 5L,
    allocated_peak_bytes: peak,
    reserved_current_bytes: 10L,
    reserved_peak_bytes: peak + 10L,
    cuda_free_bytes: 1000L - peak,
    cuda_total_bytes: 2000L,
  }
}

///|
fn telemetry_expect_failure(action : () -> Unit raise) -> Unit raise {
  try action() catch {
    _ => ()
  } noraise {
    _ => fail("expected diagnostic refusal")
  }
}

///|
fn telemetry_reserve_fixture() -> Json {
  {
    "host_mem_available_bytes": Json(100L),
    "process_unified_cgroup_path": "/",
    "mount_root_is_process_cgroup": true,
    "cgroup_metrics": {
      "memory.current": "100",
      "memory.max": "200",
      "memory.swap.current": "0",
      "memory.swap.max": "0",
    },
  }
}

///|
test "CUDA telemetry reserve accepts equality and rejects insufficient or unprovable headroom" {
  validate_telemetry_reserve(100L, telemetry_reserve_fixture(), 100L)
  validate_telemetry_reserve(0L, Json::null(), 0L)
  telemetry_expect_failure(() => {
    validate_telemetry_reserve(99L, telemetry_reserve_fixture(), 100L)
  })
  for
    (name, replacement) in [
      ("host_mem_available_bytes", Json(99L)),
      ("host_mem_available_bytes", Json::null()),
      ("host_mem_available_bytes", Json(1.5)),
      ("process_unified_cgroup_path", Json("/nested")),
      ("process_unified_cgroup_path", Json::null()),
      ("mount_root_is_process_cgroup", Json(false)),
      ("cgroup_metrics", Json::null()),
    ] {
    guard telemetry_reserve_fixture() is Object(fields) else { fail("fixture") }
    fields[name] = replacement
    telemetry_expect_failure(() => {
      validate_telemetry_reserve(100L, Json(fields), 100L)
    })
  }
  for
    (name, replacement) in [
      ("memory.current", Json("101")),
      ("memory.current", Json("201")),
      ("memory.current", Json("-1")),
      ("memory.current", Json("1.5")),
      ("memory.current", Json("9223372036854775808")),
      ("memory.max", Json("199")),
      ("memory.max", Json("max")),
      ("memory.max", Json::null()),
      ("memory.swap.current", Json("1")),
      ("memory.swap.current", Json::null()),
      ("memory.swap.max", Json("1")),
      ("memory.swap.max", Json("max")),
      ("memory.swap.max", Json::null()),
    ] {
    guard telemetry_reserve_fixture() is Object(fields) &&
      fields["cgroup_metrics"] is Object(metrics) else {
      fail("fixture")
    }
    metrics[name] = replacement
    telemetry_expect_failure(() => {
      validate_telemetry_reserve(100L, Json(fields), 100L)
    })
  }
}

///|
test "CUDA telemetry reserve records offending sample and fails window before next phase" {
  let emitted : Array[Json] = []
  let reads = [0]
  let resets = [0]
  let diagnostic = CudaTrainingTelemetry::new(
    0,
    0,
    "d".repeat(64),
    "fresh",
    0,
    () => {
      reads[0] += 1
      telemetry_fixture_stats(901L)
    },
    () => resets[0] += 1,
    telemetry_reserve_fixture,
    row => emitted.push(row),
    minimum_remaining_bytes=100L,
  )
  telemetry_expect_failure(() => diagnostic.start())
  assert_eq(diagnostic.status, "failed")
  assert_eq(diagnostic.total_samples, 1L)
  assert_eq(diagnostic.samples.length(), 1)
  assert_true(diagnostic.last is Some(_))
  assert_eq(emitted.length(), 2)
  assert_eq(
    setting(emitted[0], "format", ""),
    "moonrobo.cuda-training-memory-sample.v1",
  )
  assert_eq(
    setting(emitted[1], "format", ""),
    "moonrobo.cuda-training-telemetry-error.v1",
  )
  assert_eq(resets[0], 0)
  telemetry_expect_failure(() => diagnostic.sample("unreachable", 1))
  assert_eq(reads[0], 1)
  assert_eq(emitted.length(), 2)
}

///|
test "CUDA telemetry is explicit and launch diagnostic leaves durable identity untouched" {
  assert_false(cuda_telemetry_requested([]))
  assert_true(cuda_telemetry_requested(["train", "--cuda-memory-telemetry"]))
  assert_true(
    cuda_telemetry_requested(["--cuda-memory-telemetry", "--iterations", "1"]),
  )
  for
    args in [
      ["--cuda-memory-telemetry=true"],
      ["--cuda-memory-telemetry", "true"],
      ["--cuda-memory-telemetry", "--cuda-memory-telemetry"],
    ] {
    telemetry_expect_failure(() => ignore(cuda_telemetry_requested(args)))
  }
  validate_telemetry_capability(0, true)
  telemetry_expect_failure(() => validate_telemetry_capability(-1, true))
  telemetry_expect_failure(() => validate_telemetry_capability(0, false))
  let identity : Json = { "training_config": { "precision": "float32" } }
  let original = identity.stringify()
  assert_eq(telemetry_launch_identity(identity, false), identity)
  assert_true(telemetry_launch_identity(identity, true) != identity)
  assert_eq(identity.stringify(), original)
  let config : Json = { "num_envs": 4, "wm_microbatch": 2, "pi_microbatch": 2 }
  let disabled = settings(config, [])
  let enabled = settings(config, ["--cuda-memory-telemetry"])
  assert_eq(Json(disabled.learner), Json(enabled.learner))
  assert_eq(disabled.options.iterations, enabled.options.iterations)
  assert_eq(disabled.options.action_noise, enabled.options.action_noise)
  assert_eq(
    distributed_launch_identity(identity, disabled),
    distributed_launch_identity(identity, enabled),
  )
  let gib = 1073741824L
  let plan = estimate_memory(disabled, 64L * gib, Some(100L * gib))
  assert_eq(
    Json(plan),
    Json(estimate_memory(enabled, 64L * gib, Some(100L * gib))),
  )
  assert_eq(plan.components["physics_scene_reserve"], 24L * gib)
  assert_eq(plan.budget_bytes, 64L * gib * 65L / 100L)
}

///|
test "CUDA telemetry resets once and retains bounded prefix plus latest cumulative peaks" {
  let read_count = [0]
  let reset_count = [0]
  let emitted : Array[Json] = []
  let peaks = [100L, 10L, 20L, 30L]
  let diagnostic = CudaTrainingTelemetry::new(
    0,
    0,
    "a".repeat(64),
    "fresh",
    0,
    () => {
      let peak = peaks[read_count[0]]
      read_count[0] += 1
      telemetry_fixture_stats(peak)
    },
    () => reset_count[0] += 1,
    () => Json::empty_object(),
    row => emitted.push(row),
    max_samples=2,
  )
  diagnostic.start()
  diagnostic.sample("world_updates_complete", 1)
  diagnostic.sample("training_and_checkpoint_complete", 1)
  assert_eq(reset_count[0], 1)
  assert_eq(read_count[0], 4)
  assert_eq(diagnostic.samples.length(), 2)
  assert_eq(emitted.length(), 2)
  assert_eq(diagnostic.total_samples, 4L)
  assert_eq(diagnostic.window_samples, 3L)
  assert_eq(diagnostic.allocated_peak, 30L)
  assert_eq(diagnostic.reserved_peak, 40L)
  assert_eq(diagnostic.minimum_cuda_free, 970L)
  guard diagnostic.last is Some(last) else { fail("missing last sample") }
  assert_eq(setting(last, "phase", ""), "training_and_checkpoint_complete")
  assert_eq(setting(diagnostic.report(), "omitted_sample_count", 0L), 2L)
  telemetry_expect_failure(() => diagnostic.start())
  assert_eq(reset_count[0], 1)
}

///|
test "CUDA telemetry extended retention remains bounded and records the configured limit" {
  let emitted : Array[Json] = []
  let diagnostic = CudaTrainingTelemetry::new(
    0,
    0,
    "e".repeat(64),
    "fresh",
    0,
    () => telemetry_fixture_stats(10L),
    () => (),
    () => Json::empty_object(),
    row => emitted.push(row),
    max_samples=512,
  )
  diagnostic.start()
  for i in 0..<513 {
    diagnostic.sample("collection_complete", i)
  }
  assert_eq(diagnostic.total_samples, 515L)
  assert_eq(diagnostic.samples.length(), 512)
  assert_eq(emitted.length(), 512)
  assert_eq(setting(diagnostic.report(), "omitted_sample_count", 0L), 3L)
  guard diagnostic.report() is Object(report) else { fail("report") }
  assert_eq(setting(report["options"], "max_retained_samples", 0), 512)
  let identity : Json = {}
  guard telemetry_launch_identity(identity, true, max_samples=512)
    is Object(fields) else {
    fail("identity")
  }
  assert_eq(
    setting(
      fields["cuda_memory_telemetry_diagnostic"],
      "max_retained_samples",
      0,
    ),
    512,
  )
  for limit in [1, 1025] {
    telemetry_expect_failure(() => {
      ignore(
        CudaTrainingTelemetry::new(
          0,
          0,
          "f".repeat(64),
          "fresh",
          0,
          () => telemetry_fixture_stats(10L),
          () => (),
          () => Json::empty_object(),
          _ => (),
          max_samples=limit,
        ),
      )
    })
  }
}

///|
test "CUDA telemetry fails closed on decreasing peaks and does not fabricate a sample" {
  let read_count = [0]
  let emitted : Array[Json] = []
  let peaks = [100L, 20L, 10L]
  let diagnostic = CudaTrainingTelemetry::new(
    0,
    1,
    "b".repeat(64),
    "exact",
    7,
    () => {
      let peak = peaks[read_count[0]]
      read_count[0] += 1
      telemetry_fixture_stats(peak)
    },
    () => (),
    () => Json::empty_object(),
    row => emitted.push(row),
  )
  diagnostic.start()
  telemetry_expect_failure(() => diagnostic.sample("collection_complete", 8))
  assert_eq(diagnostic.status, "failed")
  assert_eq(diagnostic.total_samples, 2L)
  assert_eq(diagnostic.allocated_peak, 20L)
  assert_eq(emitted.length(), 3)
  telemetry_expect_failure(() => diagnostic.sample("unreachable", 8))
  assert_eq(emitted.length(), 3)
  assert_eq(read_count[0], 3)
  assert_true(diagnostic.failure is Some(_))
}

///|
test "CUDA telemetry Linux host metrics preserve missing values and explicit cgroup scope" {
  let missing = telemetry_host_snapshot(read=_ => b"\x01not available")
  guard missing is Object(missing_fields) else { fail("expected host object") }
  assert_eq(missing_fields["host_mem_available_bytes"], Json::null())
  assert_eq(missing_fields["mount_root_is_process_cgroup"], Json::null())
  guard missing_fields["read_errors"] is Object(errors) else {
    fail("expected error object")
  }
  assert_eq(errors.length(), 9)
  let present = telemetry_host_snapshot(read=index => {
    match index {
      0 => b"\x00MemAvailable: 100 kB\n"
      1 => b"\x000::/nested/process\n"
      _ => b"\x00123\n"
    }
  })
  guard present is Object(fields) else { fail("expected host object") }
  assert_eq(fields["host_mem_available_bytes"], Json(102400L))
  assert_eq(fields["mount_root_is_process_cgroup"], Json(false))
  assert_eq(fields["ancestor_limits_enumerated"], Json(false))
  assert_eq(fields["process_unified_cgroup_path"], Json("/nested/process"))
  // Exercises actual native FFI bounds without touching procfs or CUDA.
  let invalid = training_host_metric(-1)
  assert_eq(invalid[0], b'\x01')
  assert_eq(@utf8.decode(invalid[1:]), "invalid host metric index")
}

///|
async test "CUDA diagnostic persistence cannot replace a checkpoint pointer" {
  let root = @fs.tmpdir(prefix="moonrobo-cuda-telemetry-")
  defer @fs.rmdir(root, recursive=true)
  let sentinel = b"previous-valid-generation-pointer"
  @fs.write_file(root + "/current.json", sentinel, create_mode=CreateNew)
  let diagnostic = CudaTrainingTelemetry::new(
    0,
    0,
    "c".repeat(64),
    "fresh",
    0,
    () => fail("unavailable CUDA fixture"),
    () => (),
    () => Json::empty_object(),
    _ => (),
  )
  telemetry_expect_failure(() => diagnostic.start())
  save_cuda_telemetry(root, diagnostic)
  assert_eq(@fs.read_file(root + "/current.json").binary(), sentinel)
  let saved = bounded_json(
    root + "/" + diagnostic.window_id + ".json",
    1048576L,
  )
  assert_eq(setting(saved, "status", ""), "failed")
  guard saved is Object(fields) else { fail("expected diagnostic report") }
  assert_eq(fields["allocated_window_peak_bytes"], Json::null())
  assert_eq(fields["minimum_observed_cuda_free_bytes"], Json::null())
  try save_cuda_telemetry(root, diagnostic) catch {
    _ => ()
  } noraise {
    _ => fail("window persistence must not overwrite existing evidence")
  }
}
