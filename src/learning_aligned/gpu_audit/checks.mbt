///|
fn fields(snapshot : @gpu.AuditReadback) -> Map[String, Array[Array[Double]]] {
  {
    "state71": snapshot.state71,
    "root_pose": snapshot.root_pose,
    "root_com_velocity": snapshot.root_com_velocity,
    "root_com_local": snapshot.root_com_local,
    "joint_position": snapshot.joint_position,
    "joint_velocity": snapshot.joint_velocity,
    "shape_friction": snapshot.shape_friction,
    "torso_com": snapshot.torso_com,
    "ground_friction": [snapshot.ground_friction],
  }
}

///|
fn compare_values(
  checks : Array[Check],
  op : String,
  name : String,
  actual : Array[Double],
  expected : Array[Double],
  atol : Double,
  rtol~ : Double = 0.0,
) -> Unit raise {
  guard actual.length() == expected.length() &&
    actual.all(finite) &&
    expected.all(finite) else {
    fail("audit readback shape/nonfinite mismatch: " + op + "/" + name)
  }
  let mut error = 0.0
  let mut tolerance = atol
  let mut passed = true
  for i, value in actual {
    let difference = (value - expected[i]).abs()
    let allowed = atol + rtol * expected[i].abs()
    error = error.max(difference)
    tolerance = tolerance.max(allowed)
    if difference > allowed {
      passed = false
    }
  }
  checks.push({ operation: op, name, max_abs_error: error, tolerance, passed, })
}

///|
fn compare_snapshot(
  checks : Array[Check],
  op : String,
  prefix : String,
  actual : @gpu.AuditReadback,
  expected : @gpu.AuditReadback,
  atol : Double,
  rtol~ : Double = 0.0,
  worlds~ : Array[Int32] = [0, 1],
) -> Unit raise {
  let source = fields(expected)
  for name, rows in fields(actual) {
    let wanted = source[name]
    guard rows.length() == wanted.length() else {
      fail("audit field world count differs: " + name)
    }
    for i, row in rows {
      let world = if name == "ground_friction" { 0 } else { worlds[i] }
      compare_values(
        checks,
        op,
        prefix + name + "/\{world}",
        row,
        wanted[i],
        atol,
        rtol~,
      )
    }
  }
}

///|
fn check_operation(
  checks : Array[Check],
  op : Operation,
  before : @gpu.AuditReadback,
  after : @gpu.AuditReadback,
  base_com : Array[Array[Double]],
  worlds~ : Array[Int32] = [0, 1],
) -> Unit raise {
  match op.kind {
    "refresh" =>
      compare_snapshot(
        checks,
        op.id,
        "refresh-invariant/",
        after,
        before,
        0.0,
        worlds~,
      )
    "reset" => {
      let prior = fields(before)
      for row, world in worlds {
        if !op.ids.contains(world) {
          for name, rows in fields(after) {
            if name != "ground_friction" {
              compare_values(
                checks,
                op.id,
                "masked-world/\{world}/" + name,
                rows[row],
                prior[name][row],
                0.0,
              )
            }
          }
        }
      }
      for i, world in op.ids {
        guard selected_row(worlds, world) is Some(row) else { continue }
        let expected = op.states71[i].copy()
        let actual = after.state71[row]
        // q and -q encode the same orientation. Match sign only; do not hide
        // normalization, velocity-frame, origin or indexing errors.
        let dot = actual[3] * expected[3] +
          actual[4] * expected[4] +
          actual[5] * expected[5] +
          actual[6] * expected[6]
        if dot < 0.0 {
          for j in 3..<7 {
            expected[j] = -expected[j]
          }
        }
        compare_values(
          checks,
          op.id,
          "reset-state/\{world}",
          actual,
          expected,
          1.0e-5,
        )
      }
    }
    "context" => {
      for row, world in worlds {
        if !op.ids.contains(world) {
          compare_values(
            checks,
            op.id,
            "context-isolation/friction/\{world}",
            after.shape_friction[row],
            before.shape_friction[row],
            0.0,
          )
          compare_values(
            checks,
            op.id,
            "context-isolation/com/\{world}",
            after.torso_com[row],
            before.torso_com[row],
            0.0,
          )
        }
      }
      for i, world in op.ids {
        guard selected_row(worlds, world) is Some(row) else { continue }
        compare_values(
          checks,
          op.id,
          "context-write/friction/\{world}",
          after.shape_friction[row],
          Array::make(after.shape_friction[row].length(), op.context[i][0]),
          1.0e-6,
        )
        compare_values(
          checks,
          op.id,
          "context-write/com/\{world}",
          after.torso_com[row],
          Array::makei(3, j => base_com[row][j] + op.context[i][30 + j]),
          1.0e-6,
        )
      }
      compare_values(
        checks,
        op.id,
        "context-write/ground",
        after.ground_friction,
        Array::make(after.ground_friction.length(), op.ground_mu),
        1.0e-6,
      )
      // Context commits should not integrate time or replace q/root pose.
      for row, world in worlds {
        compare_values(
          checks,
          op.id,
          "context-no-integration/pose/\{world}",
          after.root_pose[row],
          before.root_pose[row],
          0.0,
        )
        compare_values(
          checks,
          op.id,
          "context-no-integration/q/\{world}",
          after.joint_position[row],
          before.joint_position[row],
          0.0,
        )
      }
    }
    _ => ()
  }
}

///|
fn selected_row(worlds : Array[Int32], world : Int32) -> Int32? {
  for i, candidate in worlds {
    if candidate == world {
      return Some(i)
    }
  }
  None
}
