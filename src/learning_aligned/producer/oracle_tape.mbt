///|
fn oracle_finite(value : Double) -> Bool {
  !value.is_nan() && !value.is_inf()
}

///|
fn oracle_rows(
  rows : Array[Array[Double]],
  count : Int32,
  width : Int32,
) -> Bool {
  rows.length() == count &&
  rows.all(row => row.length() == width && row.all(oracle_finite))
}

///|
fn oracle_worlds(n : Int32) -> Array[Int32] {
  let result = [0]
  for world in [n / 2, n - 1] {
    if !result.contains(world) {
      result.push(world)
    }
  }
  result
}

///|
/// All checks run before opening CPython, the SDK scene, or a CUDA allocation.
/// The full input file has an independent 4 MiB bound. This permits a bounded
/// v2 operation tape rather than silently relaxing the pinned v1 SHA contract.
fn OracleTape::validate(
  self : OracleTape,
  n : Int32,
  sha : String,
  diagnostic~ : Bool,
  max_envs~ : Int32 = 128,
) -> Array[Int32]? raise {
  guard n >= 2 && n <= max_envs && self.num_envs == n else {
    fail("SDK oracle tape/config world count exceeds selected capacity profile")
  }
  let selected = match self.format {
    "moonrobo.apic-audit-tape.v1" => {
      guard n == 2 &&
        self.selected_worlds is None &&
        self.operations.length() == 20 &&
        sha ==
        "cb4ffbf27aac69d5b539484f85d94273252f1496d5df9796b8c9f4564a1db860" else {
        fail("SDK oracle v1 requires the unchanged pinned two-world tape")
      }
      None
    }
    "moonrobo.apic-audit-tape.v2" => {
      guard n >= 4 &&
        !diagnostic &&
        self.selected_worlds is Some(worlds) &&
        worlds == oracle_worlds(n) else {
        fail(
          "SDK oracle v2 requires canonical first/middle/last worlds and no v1 diagnostics",
        )
      }
      Some(worlds)
    }
    _ => fail("unsupported SDK oracle tape version")
  }
  guard self.operations.length() >= 8 && self.operations.length() <= 64 else {
    fail("SDK oracle tape must contain 8..64 operations")
  }
  let names : Array[String] = []
  let kinds : Array[String] = []
  let mut step_count = 0
  for op in self.operations {
    guard !op.id.is_empty() &&
      op.id.length() <= 80 &&
      !names.contains(op.id) &&
      op.ids.length() <= n &&
      oracle_finite(op.ground_mu) &&
      op.ground_mu > 0.0 else {
      fail("invalid SDK oracle operation identity/ground friction")
    }
    let seen : Array[Int32] = []
    for id in op.ids {
      guard id >= 0 && id < n && !seen.contains(id) else {
        fail("SDK oracle world IDs must be distinct and in range")
      }
      seen.push(id)
    }
    names.push(op.id)
    kinds.push(op.kind)
    match op.kind {
      "reset" => {
        guard oracle_rows(op.states71, op.ids.length(), 71) &&
          op.targets.is_empty() &&
          op.context.is_empty() else {
          fail("invalid SDK oracle reset payload")
        }
        for state in op.states71 {
          let norm = state[3] * state[3] +
            state[4] * state[4] +
            state[5] * state[5] +
            state[6] * state[6]
          guard (norm - 1.0).abs() <= 1.0e-6 else {
            fail("SDK oracle reset requires a unit WXYZ quaternion")
          }
        }
      }
      "context" => {
        guard oracle_rows(op.context, op.ids.length(), 33) &&
          op.states71.is_empty() &&
          op.targets.is_empty() &&
          op.context.all(row => row[0] > 0.0 && row[1:30].all(x => x == 0.0)) else {
          fail("invalid SDK oracle context; joint offsets must remain zero")
        }
      }
      "step" => {
        guard oracle_rows(op.targets, n, 29) &&
          op.ids.is_empty() &&
          op.states71.is_empty() &&
          op.context.is_empty() else {
          fail("invalid SDK oracle step targets")
        }
        step_count += 1
      }
      "refresh" => {
        guard op.ids.is_empty() &&
          op.states71.is_empty() &&
          op.targets.is_empty() &&
          op.context.is_empty() else {
          fail("SDK oracle refresh accepts no payload")
        }
      }
      _ => fail("unsupported SDK oracle operation")
    }
  }
  guard step_count > 0 &&
    step_count <= 16 &&
    ["reset", "context", "step", "refresh"].all(k => kinds.contains(k)) &&
    Array::makei(kinds.length() - 1, i => {
      kinds[i] == "refresh" && kinds[i + 1] == "refresh"
    }).any(x => x) else {
    fail(
      "SDK oracle requires all four roles, repeated refresh and at most 16 steps",
    )
  }
  if selected is Some(worlds) {
    guard self.operations.any(op => op.kind == "reset" && op.ids.is_empty()) &&
      self.operations.any(op => {
        op.kind == "reset" && op.ids == Array::makei(n, i => i)
      }) &&
      worlds.all(id => {
        self.operations.any(op => op.kind == "reset" && op.ids == [id]) &&
        self.operations.any(op => op.kind == "context" && op.ids == [id])
      }) else {
      fail(
        "SDK oracle v2 requires initial all-world reset, empty reset and isolated reset/context for every selected world",
      )
    }
  }
  selected
}
