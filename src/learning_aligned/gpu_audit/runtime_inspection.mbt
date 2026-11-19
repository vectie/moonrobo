///|
struct RuntimeInspectionOptions {
  adapter : String
  device : Int32
  profile : @capacity.CapacityProfile
  output : String
}

///|
fn inspection_path(path : String) -> Unit raise {
  guard path.has_prefix("/") &&
    @utf8.encode(path).length() <= 4088 &&
    !path.contains("\u{0}") &&
    path != "/" &&
    path.split("/").drop(1).all(p => p != "" && p != "." && p != "..") else {
    fail("inspect-runtime requires bounded canonical absolute file paths")
  }
}

///|
fn runtime_inspection_options(
  args : Array[String],
) -> RuntimeInspectionOptions raise {
  guard args.length() >= 2 && args[1] == "inspect-runtime" else {
    fail("invalid inspect-runtime invocation")
  }
  let values : Map[String, String] = {}
  for i = 2; i < args.length(); i = i + 2 {
    let key = args[i]
    guard ["--adapter", "--device", "--capacity-profile", "--output"].contains(
        key,
      ) &&
      i + 1 < args.length() &&
      !values.contains(key) else {
      fail(
        "inspect-runtime rejects unknown, duplicate or missing-value options",
      )
    }
    values[key] = args[i + 1]
  }
  guard values.get("--adapter") is Some(adapter) &&
    values.get("--output") is Some(output) else {
    fail("inspect-runtime requires --adapter and --output")
  }
  inspection_path(adapter)
  inspection_path(output)
  guard adapter != output && adapter != output + ".partial" else {
    fail("inspection output must differ from adapter")
  }
  let device = @string.parse_int(values.get_or_default("--device", "0"))
  guard device >= 0 else { fail("inspection CUDA device must be nonnegative") }
  {
    adapter,
    device,
    profile: @capacity.CapacityProfile::parse(
      values.get_or_default("--capacity-profile", "initial"),
    ),
    output,
  }
}

///|
fn inspection_report(
  options : RuntimeInspectionOptions,
  native : Json,
  started : Int64,
  completed : Int64,
) -> Json raise {
  guard native is Object(fields) &&
    native
    is {
      "format": "moonrobo.apic-runtime-inspection.v1",
      "adapter_library": String(adapter),
      "adapter_library_sha256": String(digest),
      "cuda_device_index": device,
      "probe_num_envs": 2,
      "capacity_profile": String(profile),
      "cuda_free_bytes": free,
      "cuda_total_bytes": Null,
      "paper_selected_audit_capacity_checked": checked,
      "paper_selected_audit_capacity_confirmed": confirmed,
      "no_graphs_loaded": true,
      "physics_validated": false,
      ..
    } else {
    fail("invalid no-graph native runtime inspection schema")
  }
  let free_bytes : Int64 = @json.from_json(free)
  let paper = options.profile == @capacity.Paper4096
  guard adapter == options.adapter &&
    digest.length() == 64 &&
    digest.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) &&
    device == Json(options.device) &&
    profile == options.profile.name() &&
    free_bytes > 0L &&
    checked == Json(paper) &&
    confirmed == Json(paper) &&
    started >= 0L &&
    completed >= started else {
    fail("native runtime inspection identity/capability/value mismatch")
  }
  let report = fields.copy()
  report["success"] = true
  report["started_unix_ms"] = Json(started)
  report["finished_unix_ms"] = Json(completed)
  report["elapsed_ms"] = Json(completed - started)
  report["graphs_loaded"] = 0
  report["physics_steps_executed"] = 0
  report["training_executed"] = false
  report["robot_hardware_execution"] = false
  report["physics_equivalence_claimed"] = false
  report["memory_admission_granted"] = false
  report["internal_watchdog_seconds"] = 30
  report["scope"] = "temporary no-graph runtime context and current device free-memory query only"
  Json(report)
}

///|
async fn inspect_runtime_command(args : Array[String]) -> Unit {
  let options = runtime_inspection_options(args)
  let output = options.output
  let parts = output.split("/").to_array()
  let parent = if parts.length() == 2 {
    "/"
  } else {
    parts[:parts.length() - 1].join("/")
  }
  guard @fs.kind(parent, follow_symlink=false) is Directory &&
    @fs.realpath(parent) == parent &&
    !@fs.exists(output) &&
    !@fs.exists(output + ".partial") else {
    fail(
      "inspection output requires a canonical existing directory and fresh paths",
    )
  }
  guard @fs.kind(options.adapter, follow_symlink=false) is Regular &&
    @fs.realpath(options.adapter) == options.adapter else {
    fail("inspection adapter must be a canonical regular file, not a symlink")
  }
  let started = @env.now().reinterpret_as_int64()
  guard watchdog(30) else { fail("could not arm inspection watchdog") }
  defer ignore(watchdog(0))
  let report = try {
    // The shared native inspector hashes the fixed adapter in 64 KiB blocks,
    // verifies its file identity before/after the no-graph context and closes it.
    let native = @gpu.inspect_runtime_library(
      options.adapter,
      device_id=options.device,
      capacity_profile=options.profile,
    )
    inspection_report(
      options,
      native,
      started,
      @env.now().reinterpret_as_int64(),
    )
  } catch {
    error =>
      (
        {
          "format": "moonrobo.apic-runtime-inspection.v1",
          "success": false,
          "error": Json(error.to_string()),
          "adapter_library": Json(options.adapter),
          "cuda_device_index": Json(options.device),
          "capacity_profile": Json(options.profile.name()),
          "cuda_free_bytes": Json::null(),
          "cuda_total_bytes": Json::null(),
          "started_unix_ms": Json(started),
          "finished_unix_ms": Json(@env.now().reinterpret_as_int64()),
          "no_graphs_loaded": true,
          "physics_validated": false,
          "training_executed": false,
          "robot_hardware_execution": false,
          "physics_equivalence_claimed": false,
          "memory_admission_granted": false,
          "internal_watchdog_seconds": 30,
        } : Json)
  }
  let bytes = @utf8.encode(report.stringify(indent=2) + "\n")
  guard bytes.length() <= 65536 else {
    fail("inspection report exceeds 64 KiB")
  }
  @fs.write_file(output + ".partial", bytes, create_mode=CreateNew, sync=Full)
  @fs.rename(output + ".partial", output, replace=false)
  println(report.stringify())
  guard report is { "success": true, .. } else {
    fail("native runtime inspection failed; see preserved JSON report")
  }
}
