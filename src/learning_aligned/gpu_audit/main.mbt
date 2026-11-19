///|
extern "c" fn watchdog(seconds : Int32) -> Bool = "mr_apic_audit_watchdog"

///|
fn requested_self_collisions(args : Array[String]) -> Bool raise {
  let mut value : Bool? = None
  for i, arg in args {
    if arg == "--self-collisions" {
      guard value is None && i + 1 < args.length() else {
        fail("--self-collisions must appear once with true or false")
      }
      value = Some(
        match args[i + 1] {
          "true" => true
          "false" => false
          _ => fail("--self-collisions requires exactly true or false")
        },
      )
    }
  }
  value.unwrap_or(false)
}

///|
async fn run_replay(
  args : Array[String],
  diagnostic : Bool,
  self_collisions : Bool,
  capacity_profile : @capacity.CapacityProfile,
) -> Json {
  let capacity = audit_capacity(capacity_profile)
  let tape_path = required(args, "--tape")
  let (tape_json, tape_sha256) = read_json_hashed(
    tape_path,
    capacity.tape_bytes,
  )
  let tape : Tape = @json.from_json(tape_json)
  tape.validate(capacity_profile~)
  guard !diagnostic || tape.format == "moonrobo.apic-audit-tape.v1" else {
    fail("diagnostic protocol remains v1 N2 only")
  }
  let manifest = required(args, "--manifest")
  let (manifest_json, manifest_sha256) = read_json_hashed(
    manifest,
    capacity.manifest_bytes,
  )
  guard manifest_sha256 == required(args, "--manifest-sha256") else {
    fail("audit manifest hash differs from pinned input")
  }
  validate_manifest_capacity(manifest_json, capacity_profile)
  let scene_sha256 = hash_file(required(args, "--scene"), 16777216L)
  let adapter_path = required(args, "--adapter")
  let adapter_sha256 = hash_file(adapter_path, 268435456L)
  // Keep the raising option lookup outside a conditional guard expression:
  // native release coroutine lowering otherwise duplicates continuations.
  let forbidden_option = if diagnostic {
    "--oracle"
  } else {
    "--diagnostic-sdk"
  }
  guard option(args, forbidden_option) is None else {
    fail("use diagnose --diagnostic-sdk or run --oracle as separate protocols")
  }
  let sdk_diagnostic = if diagnostic {
    Some(
      read_sdk_diagnostic(
        required(args, "--diagnostic-sdk"),
        manifest_sha256,
        tape_sha256,
        tape,
      ),
    )
  } else {
    None
  }
  let sdk_diagnostic_sha = if diagnostic {
    Some(hash_file(required(args, "--diagnostic-sdk"), 16777216L))
  } else {
    None
  }
  let (oracle, oracle_sha256) : (Oracle?, String?) = match
    option(args, "--oracle") {
    None => (None, None)
    Some(path) => {
      let (source_json, source_sha256) = read_json_hashed(path, 16777216L)
      validate_manifest_capacity(source_json, capacity_profile)
      let source : Oracle = @json.from_json(source_json)
      source.validate_selection(tape)
      guard source.bundle_manifest_sha256 == manifest_sha256 &&
        source.tape_sha256 == tape_sha256 &&
        source.snapshots.length() == tape.operations.length() &&
        source.sdk_identity
        is {
          "implementation_backend": "actual-isaaclab3-newton",
          "warp": "1.17.0",
          "isaaclab_revision": "46d6cc3d7b115906fad12efd372fbf69f4e3d3ed",
          "newton_revision": "71eeba16a717d4dcf0b9dd7056a7b6f863054dc3",
          "mujoco_warp": "3.15.0",
          ..
        } else {
        fail("SDK oracle identity/manifest/input/operation count mismatch")
      }
      for i, snapshot in source.snapshots {
        guard snapshot.id == tape.operations[i].id else {
          fail("SDK oracle operation ordering mismatch")
        }
      }
      (Some(source), Some(source_sha256))
    }
  }
  let plan = preflight(args, tape.num_envs, capacity_profile)
  println(
    ({ "stage": "bounded-apic-preflight", "budget": Json(plan) } : Json).stringify(),
  )
  let native = @gpu.load(
    adapter_path,
    manifest,
    scene_sha256,
    self_collisions~,
    device_id=@string.parse_int(option(args, "--device").unwrap_or("0")),
    expected_manifest_sha256=manifest_sha256,
    capacity_profile~,
  )
  execute_replay(
    native, tape, manifest_sha256, scene_sha256, adapter_sha256, tape_sha256, plan,
    oracle, oracle_sha256, sdk_diagnostic, sdk_diagnostic_sha, diagnostic, self_collisions,
    capacity_profile,
  )
}

///|
// All I/O/preflight completes before this synchronous, scoped native handle.
fn execute_replay(
  native : @gpu.NativeBatch,
  tape : Tape,
  manifest_sha256 : String,
  scene_sha256 : String,
  adapter_sha256 : String,
  tape_sha256 : String,
  plan : Budget,
  oracle : Oracle?,
  oracle_sha256 : String?,
  sdk_diagnostic : SDKDiagnostic?,
  sdk_diagnostic_sha : String?,
  diagnostic : Bool,
  self_collisions : Bool,
  capacity_profile : @capacity.CapacityProfile,
) -> Json raise {
  defer native.close()
  let adapter = native.adapter()
  guard adapter.num_envs == tape.num_envs else {
    fail("APIC audit actual world count differs from pinned tape")
  }
  let legacy = tape.format == "moonrobo.apic-audit-tape.v1"
  let worlds = tape.worlds()
  let layout = if legacy {
    native.audit_layout()
  } else {
    native.audit_layout_selected(worlds)
  }
  guard layout is { "torso_com_base": raw_base, .. } else {
    fail("audit model layout missing")
  }
  let base_com : Array[Array[Double]] = @json.from_json(raw_base)
  guard rows_valid(base_com, worlds.length(), 3) else {
    fail("invalid audit COM baseline")
  }
  let snapshots : Array[Snapshot] = []
  let checks : Array[Check] = []
  let oracle_checks : Array[Check] = []
  let diagnostic_snapshots : Array[DiagnosticSnapshot] = []
  let input_checks : Array[Check] = []
  let diagnostic_physical_checks : Array[Check] = []
  let mut before = if legacy {
    native.audit_readback()
  } else {
    native.audit_readback_selected(worlds)
  }
  validate_readback(before, worlds.length())
  let initial = before
  let mut step_change = 0.0
  let failure : String? = try {
    for i, op in tape.operations {
      match op.kind {
        "reset" =>
          (adapter.write_resets)(
            op.ids,
            op.states71.map(@aligned.unflatten_state),
          )
        "context" => (adapter.apply_context)(op.ids, op.context, op.ground_mu)
        "step" => (adapter.step_substeps)(op.targets, 4, 0.005)
        "refresh" => native.refresh()
        _ => fail("invalid operation after validation")
      }
      (adapter.synchronize)()
      let after = if legacy {
        native.audit_readback()
      } else {
        native.audit_readback_selected(worlds)
      }
      validate_readback(after, worlds.length())
      check_operation(checks, op, before, after, base_com, worlds~)
      if op.kind == "step" {
        for world in 0..<worlds.length() {
          for j in 0..<71 {
            step_change = step_change.max(
              (after.state71[world][j] - before.state71[world][j]).abs(),
            )
          }
        }
      }
      if oracle is Some(source) {
        compare_snapshot(
          oracle_checks,
          op.id,
          "sdk/",
          after,
          source.snapshots[i].readback,
          1.0e-5,
          rtol=1.0e-5,
          worlds~,
        )
      }
      snapshots.push({ id: op.id, readback: after, })
      if sdk_diagnostic is Some(source) {
        let actual = native.audit_diagnostics()
        compare_diagnostic_inputs(
          input_checks,
          op,
          actual,
          source.snapshots[i].diagnostic,
        )
        compare_snapshot(
          diagnostic_physical_checks,
          op.id,
          "diagnostic-sdk/",
          after,
          source.snapshots[i].readback,
          1.0e-5,
          rtol=1.0e-5,
        )
        diagnostic_snapshots.push({
          id: op.id,
          readback: after,
          diagnostic: actual,
        })
      }
      before = after
      println(
        (
          { "stage": "apic-operation-complete", "id": op.id, "kind": op.kind } :
          Json).stringify(),
      )
    }
    None
  } catch {
    error => Some(error.to_string())
  }
  let complete = snapshots.length() == tape.operations.length() &&
    failure is None
  let self_ok = complete && checks.all(c => c.passed) && step_change > 0.0
  let oracle_ok = complete && oracle_checks.all(c => c.passed)
  let diagnostic_ok = complete &&
    !input_checks.is_empty() &&
    input_checks.all(c => c.passed) &&
    diagnostic_physical_checks.all(c => c.passed)
  let success = self_ok &&
    (oracle is None || oracle_ok) &&
    (!diagnostic || diagnostic_ok)
  let report : Json = {
    "format": Json(
      if diagnostic {
        "moonrobo.apic-replay-diagnostic.v1"
      } else if legacy {
        "moonrobo.apic-replay-audit.v1"
      } else {
        "moonrobo.apic-replay-audit.v2"
      },
    ),
    "success": success,
    "native_gpu_operations_executed": true,
    "fake_adapter_used": false,
    "bundle_manifest_sha256": manifest_sha256,
    "scene_sha256": scene_sha256,
    "adapter_sha256": adapter_sha256,
    "self_collisions": Json(self_collisions),
    "capacity_profile": capacity_profile.name(),
    "tape_sha256": tape_sha256,
    "identity": native.identity(),
    "layout": layout,
    "budget": Json(plan),
    "num_envs": tape.num_envs,
    "operation_count": snapshots.length(),
    "requested_operations": tape.operations.length(),
    "self_consistency_passed": self_ok,
    "maximum_state_change_during_step": step_change,
    "oracle_comparison_performed": oracle is Some(_),
    "oracle_sha256": Json(oracle_sha256),
    "oracle_equal": if oracle is Some(_) {
      Json(oracle_ok)
    } else {
      Json::null()
    },
    "oracle_status": if oracle is Some(_) {
      "executed-trace-comparison"
    } else {
      "unverified-no-sdk-trace"
    },
    "oracle_atol": 1.0e-5,
    "oracle_rtol": 1.0e-5,
    "error": Json(failure),
    "initial": Json(initial),
    "snapshots": Json(snapshots),
    "checks": Json(checks),
    "oracle_checks": Json(oracle_checks),
    "training_executed": false,
    "robot_hardware_execution": false,
    "physics_equivalence_claimed": false,
    "known_sdk_numerical_gap_unresolved": true,
    "comparison_scope": "this pinned executed trace only; no global physics equivalence claim",
  }
  let mut result = report
  if !legacy {
    let fields : Map[String, Json] = @json.from_json(result)
    fields["selected_worlds"] = Json(worlds)
    fields["readback_scope"] = "selected primitive rows only; other worlds are simulated, not observed"
    let completed_steps = tape.operations[:snapshots.length()]
      .filter(op => op.kind == "step")
      .length()
    fields["simulated_world_steps"] = Json(tape.num_envs * completed_steps)
    fields["simulated_world_substeps"] = Json(
      tape.num_envs * completed_steps * 4,
    )
    result = Json(fields)
  }
  if diagnostic {
    let fields : Map[String, Json] = @json.from_json(report)
    fields["diagnostic_sdk_sha256"] = Json(sdk_diagnostic_sha)
    fields["diagnostic_snapshots"] = Json(diagnostic_snapshots)
    fields["exact_input_checks"] = Json(input_checks)
    fields["exact_inputs_passed"] = Json(
      complete && !input_checks.is_empty() && input_checks.all(c => c.passed),
    )
    fields["diagnostic_physical_checks"] = Json(diagnostic_physical_checks)
    fields["diagnostic_physical_checks_passed"] = Json(
      complete && diagnostic_physical_checks.all(c => c.passed),
    )
    fields["solver_internal_views_available"] = false
    fields["substep_diagnostics_available"] = false
    result = Json(fields)
  }
  result
}

///|
async fn main {
  let args = @env.args()
  if args.length() >= 2 && args[1] == "inspect-runtime" {
    inspect_runtime_command(args)
    return
  }
  guard args.length() >= 2 && ["emit-tape", "run", "diagnose"].contains(args[1]) else {
    fail(
      "usage: gpu_audit inspect-runtime --adapter /absolute/LIB --device 0 --capacity-profile initial|paper-4096 --output /fresh/REPORT.json | emit-tape --output TAPE.json [--num-envs 2|4..4096] | {run|diagnose} --adapter LIB --manifest FILE --manifest-sha256 SHA --scene MJCF --tape TAPE.json --output REPORT.json [run: --oracle SDK_TRACE.json; diagnose: --diagnostic-sdk SDK_DIAGNOSTIC.json (N2 only)] [--capacity-profile initial|paper-4096 --self-collisions true|false --device 0 --max-host-mib 8192 --max-device-mib 8192 --timeout-seconds 180]",
    )
  }
  let output = required(args, "--output")
  let capacity_profile = requested_capacity(args)
  let capacity = audit_capacity(capacity_profile)
  guard !@fs.exists(output) else { fail("audit output must be fresh") }
  if args[1] == "emit-tape" {
    let count = @string.parse_int(option(args, "--num-envs").unwrap_or("2"))
    if count != 2 {
      validate_selected_count(count, capacity_profile)
    }
    if count > 128 {
      require_json_headroom(capacity.tape_bytes, host_available())
    }
    let tape = if count == 2 {
      default_tape()
    } else {
      selected_tape(count, capacity_profile~)
    }
    tape.validate(capacity_profile~)
    let bytes = @utf8.encode(Json(tape).stringify(indent=2) + "\n")
    guard bytes.length().to_int64() <= capacity.tape_bytes else {
      fail("emitted audit tape exceeds selected profile byte bound")
    }
    @fs.write_file(output, bytes, create_mode=CreateNew, sync=Full)
    println(
      (
        {
          "format": Json(
            if count == 2 {
              "moonrobo.apic-audit-tape-created.v1"
            } else {
              "moonrobo.apic-audit-tape-created.v2"
            },
          ),
          "output": output,
          "sha256": hash_file(output, capacity.tape_bytes),
          "capacity_profile": capacity_profile.name(),
          "operations": tape.operations.length(),
        } : Json).stringify(),
    )
    return
  }
  let seconds = @string.parse_int(
    option(args, "--timeout-seconds").unwrap_or("180"),
  )
  guard watchdog(seconds) else { fail("audit watchdog must be 5..600 seconds") }
  defer ignore(watchdog(0))
  let self_collisions = requested_self_collisions(args)
  let report = run_replay(
    args,
    args[1] == "diagnose",
    self_collisions,
    capacity_profile,
  ) catch {
    error =>
      (
        {
          "format": Json(
            if args[1] == "diagnose" {
              "moonrobo.apic-replay-diagnostic.v1"
            } else {
              "moonrobo.apic-replay-audit.v1"
            },
          ),
          "success": false,
          "error": error.to_string(),
          "self_collisions": Json(self_collisions),
          "capacity_profile": capacity_profile.name(),
          "oracle_status": "unverified",
          "training_executed": false,
        } : Json)
  }
  @fs.write_file(
    output,
    @utf8.encode(report.stringify(indent=2) + "\n"),
    create_mode=CreateNew,
    sync=Full,
  )
  println(report.stringify())
  guard report is { "success": true, .. } else {
    fail("APIC replay audit failed; see preserved JSON report")
  }
}
