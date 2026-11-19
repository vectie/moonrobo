///|
struct DiagnosticSnapshot {
  id : String
  readback : @gpu.AuditReadback
  diagnostic : Json
} derive(ToJson, FromJson)

///|
struct SDKDiagnostic {
  format : String
  success : Bool
  bundle_manifest_sha256 : String
  tape_sha256 : String
  sdk_identity : Json
  snapshots : Array[DiagnosticSnapshot]
  writer_comparisons : Array[Json]
} derive(FromJson)

///|
async fn read_sdk_diagnostic(
  path : String,
  manifest_sha : String,
  tape_sha : String,
  tape : Tape,
) -> SDKDiagnostic {
  let source : SDKDiagnostic = @json.from_json(read_json(path, 16777216L))
  guard source.format == "moonrobo.apic-sdk-diagnostic.v1" &&
    source.success &&
    source.bundle_manifest_sha256 == manifest_sha &&
    source.tape_sha256 == tape_sha &&
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
    fail("SDK diagnostic identity/input/count/success mismatch")
  }
  for i, snapshot in source.snapshots {
    guard snapshot.id == tape.operations[i].id else {
      fail("SDK diagnostic operation order mismatch")
    }
  }
  let steps = tape.operations.filter(op => op.kind == "step")
  guard source.writer_comparisons.length() == steps.length() else {
    fail("missing SDK writer probes")
  }
  for i, record in source.writer_comparisons {
    guard record
      is {
        "operation": String(id),
        "passed": true,
        "poison_readback_verified": true,
        "original_outputs_restored": true,
        "physical_state_unchanged": true,
        "solver_arrays_unchanged": true,
        "staging_inputs_unchanged": true,
        "user_inputs_unchanged": true,
        "physics_steps_between_writers": 0,
        ..
      } &&
      id == steps[i].id else {
      fail("SDK diagnostic lacks a successful isolated writer comparison")
    }
  }
  source
}

///|
// Compare only semantically consumed input rows. Unselected reset rows are
// scratch storage, and the original SDK/native paths may fill them differently.
// The complete real arrays still remain in both diagnostic reports.
fn compare_diagnostic_inputs(
  checks : Array[Check],
  op : Operation,
  actual : Json,
  expected : Json,
) -> Unit raise {
  guard actual is { "inputs": a, .. } && expected is { "inputs": b, .. } else {
    fail("diagnostic input views missing")
  }
  let left : Map[String, Array[Array[Double]]] = @json.from_json(a)
  let right : Map[String, Array[Array[Double]]] = @json.from_json(b)
  let selected : Array[(String, Int32, Array[Int32])] = match op.kind {
    "step" => [("targets", 29, [0, 1])]
    "reset" if !op.ids.is_empty() =>
      [
        ("reset_mask", 1, [0, 1]),
        ("reset_pose", 7, op.ids),
        ("reset_velocity", 6, op.ids),
        ("reset_joint_position", 29, op.ids),
        ("reset_joint_velocity", 29, op.ids),
      ]
    _ => []
  }
  for (name, width, worlds) in selected {
    guard left.get(name) is Some(rows) &&
      right.get(name) is Some(wanted) &&
      rows_valid(rows, 2, width) &&
      rows_valid(wanted, 2, width) else {
      fail("invalid actual diagnostic view: " + name)
    }
    for world in worlds {
      compare_values(
        checks,
        op.id,
        "exact-input/" + name + "/\{world}",
        rows[world],
        wanted[world],
        0.0,
      )
    }
  }
}
