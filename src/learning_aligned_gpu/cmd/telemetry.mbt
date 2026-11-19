///|
fn cuda_telemetry_requested(args : Array[String]) -> Bool raise {
  let mut enabled = false
  for i, arg in args {
    guard !arg.has_prefix("--cuda-memory-telemetry=") else {
      fail("--cuda-memory-telemetry is a standalone opt-in flag")
    }
    if arg == "--cuda-memory-telemetry" {
      guard !enabled && (i + 1 == args.length() || args[i + 1].has_prefix("--")) else {
        fail("duplicate --cuda-memory-telemetry or unexpected option value")
      }
      enabled = true
    }
  }
  enabled
}

///|
fn validate_telemetry_capability(
  device : Int32,
  available : Bool,
) -> Unit raise {
  guard device >= 0 else {
    fail("CUDA memory telemetry requires a CUDA learner")
  }
  guard available else {
    fail(
      "--cuda-memory-telemetry requires the optional allocator telemetry plugin symbols; no fallback",
    )
  }
}

///|
fn telemetry_options(max_samples~ : Int32 = 128) -> Json {
  {
    "format": "moonrobo.cuda-training-telemetry-options.v1",
    "enabled": true,
    "synchronize_each_sample": true,
    "reset_peaks": "once after initialization and checkpoint restore",
    "max_retained_samples": Json(max_samples),
    "max_event_bytes": 16384,
    "affects_performance": true,
    "changes_training_identity": false,
    "caching_precondition": "fixed enabled allocator; no external cache/peak mutation",
    "programmatic_cache_disable_checked": false,
  }
}

///|
fn telemetry_launch_identity(
  value : Json,
  enabled : Bool,
  max_samples~ : Int32 = 128,
) -> Json raise {
  if !enabled {
    return value
  }
  guard value is Object(fields) else {
    fail("launch identity must be an object")
  }
  let result = fields.copy()
  result["cuda_memory_telemetry_diagnostic"] = telemetry_options(max_samples~)
  Json(result)
}

///|
priv struct CudaTrainingTelemetry {
  device : Int32
  rank : Int32
  identity_sha256 : String
  resume_kind : String
  start_iteration : Int32
  window_id : String
  read_stats : () -> @tensor.CudaMemoryStats raise
  reset_peaks : () -> Unit raise
  host_snapshot : () -> Json
  emit : (Json) -> Unit
  samples : Array[Json]
  max_samples : Int32
  minimum_remaining_bytes : Int64
  mut last : Json?
  mut total_samples : Int64
  mut window_samples : Int64
  mut resets : Int32
  mut allocated_peak : Int64
  mut reserved_peak : Int64
  mut minimum_cuda_free : Int64
  mut status : String
  mut failure : String?
}

///|
fn CudaTrainingTelemetry::new(
  device : Int32,
  rank : Int32,
  identity_sha256 : String,
  resume_kind : String,
  start_iteration : Int32,
  read_stats : () -> @tensor.CudaMemoryStats raise,
  reset_peaks : () -> Unit raise,
  host_snapshot : () -> Json,
  emit : (Json) -> Unit,
  max_samples~ : Int32 = 128,
  minimum_remaining_bytes~ : Int64 = 0L,
) -> CudaTrainingTelemetry raise {
  guard device >= 0 &&
    rank >= 0 &&
    start_iteration >= 0 &&
    max_samples >= 2 &&
    max_samples <= 1024 &&
    minimum_remaining_bytes >= 0L else {
    fail("invalid telemetry window bounds")
  }
  let now = unix_milliseconds()
  guard now > 0L else { fail("telemetry wall clock unavailable") }
  {
    device,
    rank,
    identity_sha256,
    resume_kind,
    start_iteration,
    window_id: "cuda-memory-\{now}-rank-\{rank}-iteration-\{start_iteration}",
    read_stats,
    reset_peaks,
    host_snapshot,
    emit,
    max_samples,
    minimum_remaining_bytes,
    samples: [],
    last: None,
    total_samples: 0L,
    window_samples: 0L,
    resets: 0,
    allocated_peak: 0L,
    reserved_peak: 0L,
    minimum_cuda_free: 9223372036854775807L,
    status: "recording",
    failure: None,
  }
}

///|
fn telemetry_required_bytes(
  fields : Map[String, Json],
  name : String,
) -> Int64 raise {
  // Int64 telemetry JSON uses exact decimal strings, including host MemAvailable.
  guard fields.get(name) is Some(String(text)) &&
    text.length() > 0 &&
    text.iter().all(c => c is ('0'..<='9')) else {
    fail("remaining-memory guard requires a nonnegative decimal: " + name)
  }
  @string.parse_int64(text)
}

///|
fn validate_telemetry_reserve(
  cuda_free : Int64,
  host : Json,
  minimum : Int64,
) -> Unit raise {
  if minimum == 0L {
    return
  }
  guard minimum > 0L && cuda_free >= minimum else {
    fail("remaining-memory guard: CUDA free bytes below reserve")
  }
  guard host is Object(fields) &&
    fields.get("process_unified_cgroup_path") == Some(Json("/")) &&
    fields.get("mount_root_is_process_cgroup") == Some(Json(true)) &&
    fields.get("cgroup_metrics") is Some(Object(metrics)) else {
    fail(
      "remaining-memory guard requires the current process cgroup at visible mount root",
    )
  }
  guard telemetry_required_bytes(fields, "host_mem_available_bytes") >= minimum else {
    fail("remaining-memory guard: host MemAvailable below reserve")
  }
  let current = telemetry_required_bytes(metrics, "memory.current")
  let maximum = telemetry_required_bytes(metrics, "memory.max")
  guard maximum > 0L && current <= maximum && maximum - current >= minimum else {
    fail("remaining-memory guard: finite cgroup headroom below reserve")
  }
  guard telemetry_required_bytes(metrics, "memory.swap.current") == 0L &&
    telemetry_required_bytes(metrics, "memory.swap.max") == 0L else {
    fail("remaining-memory guard requires cgroup swap.current=0 and swap.max=0")
  }
}

///|
fn CudaTrainingTelemetry::error(
  self : CudaTrainingTelemetry,
  phase : String,
  error : Error,
) -> Unit {
  self.status = "failed"
  if self.failure is None {
    let message = error.to_string()[0:4096].to_owned()
    self.failure = Some(message)
    (self.emit)({
      "format": "moonrobo.cuda-training-telemetry-error.v1",
      "window_id": Json(self.window_id),
      "phase": Json(phase),
      "error": Json(message),
    })
  }
}

///|
fn CudaTrainingTelemetry::sample(
  self : CudaTrainingTelemetry,
  phase : String,
  iteration : Int32,
) -> Unit raise {
  try {
    guard self.status == "recording" else {
      fail("telemetry window is not recording")
    }
    let begin = unix_milliseconds()
    let stats = (self.read_stats)()
    guard stats.device == self.device &&
      stats.synchronized &&
      stats.allocated_current_bytes >= 0L &&
      stats.allocated_peak_bytes >= stats.allocated_current_bytes &&
      stats.reserved_current_bytes >= 0L &&
      stats.reserved_peak_bytes >= stats.reserved_current_bytes &&
      stats.cuda_free_bytes >= 0L &&
      stats.cuda_total_bytes >= stats.cuda_free_bytes else {
      fail("invalid synchronized telemetry snapshot")
    }
    if self.resets == 1 {
      guard stats.allocated_peak_bytes >= self.allocated_peak &&
        stats.reserved_peak_bytes >= self.reserved_peak else {
        fail(
          "allocator peaks decreased within the window; external reset or unsupported accounting",
        )
      }
    }
    let host = (self.host_snapshot)()
    let row : Json = {
      "format": "moonrobo.cuda-training-memory-sample.v1",
      "window_id": Json(self.window_id),
      "identity_sha256": Json(self.identity_sha256),
      "sequence": Json(self.total_samples),
      "phase": Json(phase),
      "iteration": Json(iteration),
      "rank": Json(self.rank),
      "sample_begin_unix_ms": Json(begin),
      "sample_end_unix_ms": Json(unix_milliseconds()),
      "peak_origin": if self.resets == 0 {
        "process before diagnostic reset"
      } else {
        "diagnostic window reset"
      },
      "allocator": stats.to_json(),
      "host": host,
    }
    guard @utf8.encode(row.stringify()).length() <= 16384 else {
      fail("telemetry event exceeds 16 KiB")
    }
    if self.resets == 1 {
      self.window_samples += 1L
      self.allocated_peak = stats.allocated_peak_bytes
      self.reserved_peak = stats.reserved_peak_bytes
      self.minimum_cuda_free = self.minimum_cuda_free.min(stats.cuda_free_bytes)
    }
    self.total_samples += 1L
    self.last = Some(row)
    if self.samples.length() < self.max_samples {
      self.samples.push(row)
      (self.emit)(row)
    }
    // Preserve the measured row even when the opt-in guard stops the next phase.
    // These are stage boundaries, not continuous monitoring or an OOM guarantee.
    validate_telemetry_reserve(
      stats.cuda_free_bytes,
      host,
      self.minimum_remaining_bytes,
    )
  } catch {
    error => {
      self.error(phase, error)
      raise error
    }
  }
}

///|
fn CudaTrainingTelemetry::start(self : CudaTrainingTelemetry) -> Unit raise {
  guard self.resets == 0 && self.total_samples == 0L else {
    fail("telemetry window already started")
  }
  self.sample(
    "initialization_and_restore_complete_before_reset",
    self.start_iteration,
  )
  try {
    (self.reset_peaks)()
    self.resets = 1
  } catch {
    error => {
      self.error("reset_peaks", error)
      raise error
    }
  }
  self.sample("window_start", self.start_iteration)
}

///|
fn CudaTrainingTelemetry::report(self : CudaTrainingTelemetry) -> Json {
  {
    "format": "moonrobo.cuda-training-memory-report.v1",
    "options": telemetry_options(max_samples=self.max_samples),
    "status": Json(self.status),
    "window_id": Json(self.window_id),
    "identity_sha256": Json(self.identity_sha256),
    "rank": Json(self.rank),
    "resume_kind": Json(self.resume_kind),
    "starting_iteration": Json(self.start_iteration),
    "resume_semantics": "new process window after restore; allocator peaks are not checkpoint state",
    "durable_training_identity_changed_by_flag": false,
    "checkpoint_failure_semantics": "failure stops training; before atomic publication the old valid pointer remains, after publication the new valid pointer remains; no diagnostic rollback",
    "window_scope": "after GPU initialization/restore through requested training and checkpoint publication; excludes report serialization and environment teardown",
    "allocator_scope": "active process allocator/pool; allocations outside that allocator/pool excluded; not total device usage",
    "phase_peak_semantics": "cumulative since one window reset, not independently reset phase peaks",
    "host_scope": "sequential Linux MemAvailable and visible cgroup mount-root observations; not atomic or added to allocator counts",
    "peak_reset_count": Json(self.resets),
    "sample_count": Json(self.total_samples),
    "retained_sample_count": Json(self.samples.length()),
    "omitted_sample_count": Json(
      self.total_samples - self.samples.length().to_int64(),
    ),
    "samples": Json(self.samples),
    "last_sample": self.last.unwrap_or(Json::null()),
    "allocated_window_peak_bytes": if self.window_samples > 0L {
      Json(self.allocated_peak)
    } else {
      Json::null()
    },
    "reserved_window_peak_bytes": if self.window_samples > 0L {
      Json(self.reserved_peak)
    } else {
      Json::null()
    },
    "minimum_observed_cuda_free_bytes": if self.window_samples > 0L {
      Json(self.minimum_cuda_free)
    } else {
      Json::null()
    },
    "error": self.failure.map(x => Json(x)).unwrap_or(Json::null()),
    "memory_admission_modified": false,
    "minimum_remaining_bytes": Json(self.minimum_remaining_bytes),
    "remaining_memory_guard_scope": "opt-in stage boundaries only; sequential observations, not continuous monitoring or an OOM guarantee",
    "empty_cache_called": false,
  }
}

///|
async fn save_cuda_telemetry(
  output : String,
  telemetry : CudaTrainingTelemetry,
) -> Unit {
  @fs.write_file(
    output + "/" + telemetry.window_id + ".json",
    telemetry.report().stringify(indent=2) + "\n",
    create_mode=CreateNew,
    sync=Full,
  )
}
