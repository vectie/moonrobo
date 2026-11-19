///|
struct Operation {
  id : String
  kind : String
  ids : Array[Int32]
  states71 : Array[Array[Double]]
  targets : Array[Array[Double]]
  context : Array[Array[Double]]
  ground_mu : Double
} derive(ToJson, FromJson)

///|
struct Tape {
  format : String
  num_envs : Int32
  operations : Array[Operation]
  selected_worlds : Array[Int32]?
} derive(ToJson, FromJson)

///|
struct Snapshot {
  id : String
  readback : @gpu.AuditReadback
} derive(ToJson, FromJson)

///|
struct Oracle {
  format : String
  bundle_manifest_sha256 : String
  tape_sha256 : String
  sdk_identity : Json
  snapshots : Array[Snapshot]
  num_envs : Int32?
  selected_worlds : Array[Int32]?
} derive(FromJson)

///|
struct Check {
  operation : String
  name : String
  max_abs_error : Double
  tolerance : Double
  passed : Bool
} derive(ToJson)

///|
fn finite(value : Double) -> Bool {
  !value.is_nan() && !value.is_inf()
}

///|
fn rows_valid(
  rows : Array[Array[Double]],
  count : Int32,
  width : Int32,
) -> Bool {
  rows.length() == count &&
  rows.all(row => row.length() == width && row.all(finite))
}

///|
fn Tape::validate(
  self : Tape,
  capacity_profile~ : @capacity.CapacityProfile = Initial,
) -> Unit raise {
  let legacy = self.format == "moonrobo.apic-audit-tape.v1"
  guard (if legacy {
      self.num_envs == 2 && self.selected_worlds is None
    } else {
      self.format == "moonrobo.apic-audit-tape.v2" &&
      self.num_envs >= 4 &&
      self.num_envs <= audit_capacity(capacity_profile).worlds &&
      self.selected_worlds == Some([0, self.num_envs / 2, self.num_envs - 1])
    }) &&
    self.operations.length() >= 8 &&
    self.operations.length() <= 64 else {
    fail(
      "audit tape requires v1 N2 or bounded-profile v2 with first/middle/last selection, 8..64 operations",
    )
  }
  let ids : Array[String] = []
  let kinds : Array[String] = []
  for op in self.operations {
    guard !op.id.is_empty() &&
      op.id.length() <= 80 &&
      !ids.contains(op.id) &&
      op.ids.length() <= self.num_envs &&
      op.ids.all(i => i >= 0 && i < self.num_envs) &&
      finite(op.ground_mu) &&
      op.ground_mu > 0.0 else {
      fail("invalid operation identity/world IDs/ground friction")
    }
    for i, world in op.ids {
      guard !op.ids[:i].contains(world) else {
        fail("duplicate audit world ID")
      }
    }
    ids.push(op.id)
    kinds.push(op.kind)
    match op.kind {
      "reset" => {
        guard rows_valid(op.states71, op.ids.length(), 71) &&
          op.targets.is_empty() &&
          op.context.is_empty() else {
          fail("invalid reset payload")
        }
        for state in op.states71 {
          let norm = state[3] * state[3] +
            state[4] * state[4] +
            state[5] * state[5] +
            state[6] * state[6]
          guard (norm - 1.0).abs() <= 1.0e-6 else {
            fail("reset quaternion must be unit WXYZ")
          }
        }
      }
      "context" => {
        guard rows_valid(op.context, op.ids.length(), 33) &&
          op.states71.is_empty() &&
          op.targets.is_empty() &&
          op.context.all(row => row[0] > 0.0 && row[1:30].all(x => x == 0.0)) else {
          fail("invalid context payload; audit keeps joint offsets zero")
        }
      }
      "step" => {
        guard rows_valid(op.targets, self.num_envs, 29) &&
          op.ids.is_empty() &&
          op.context.is_empty() &&
          op.states71.is_empty() else {
          fail("invalid step payload")
        }
      }
      "refresh" => {
        guard op.ids.is_empty() &&
          op.context.is_empty() &&
          op.states71.is_empty() &&
          op.targets.is_empty() else {
          fail("refresh accepts no payload")
        }
      }
      _ => fail("unsupported APIC audit operation")
    }
  }
  guard ["reset", "context", "step", "refresh"].all(k => kinds.contains(k)) else {
    fail("audit tape must execute all four graph roles")
  }
  if legacy {
    guard self.operations.any(op => op.kind == "reset" && op.ids == [0]) &&
      self.operations.any(op => op.kind == "reset" && op.ids == [1]) &&
      self.operations.any(op => op.kind == "context" && op.ids.length() == 1) else {
      fail(
        "v1 audit requires both isolated reset masks and one isolated context",
      )
    }
  } else {
    guard self.operations.filter(op => op.kind == "step").length() <= 16 &&
      self.operations.any(op => {
        op.kind == "reset" && op.ids == Array::makei(self.num_envs, i => i)
      }) &&
      self.operations.any(op => op.kind == "reset" && op.ids.is_empty()) else {
      fail("v2 audit requires all-world and empty resets, at most 16 steps")
    }
    for world in self.worlds() {
      guard self.operations.any(op => op.kind == "reset" && op.ids == [world]) &&
        self.operations.any(op => op.kind == "context" && op.ids == [world]) else {
        fail(
          "v2 audit requires isolated reset and context for every selected world",
        )
      }
    }
  }
  guard self.operations.length() > 1 &&
    Array::makei(self.operations.length() - 1, i => {
      self.operations[i].kind == "refresh" &&
      self.operations[i + 1].kind == "refresh"
    }).any(x => x) else {
    fail("audit tape must include consecutive refresh operations")
  }
}

///|
fn Tape::worlds(self : Tape) -> Array[Int32] {
  self.selected_worlds.unwrap_or([0, 1])
}

///|
fn Oracle::validate_selection(self : Oracle, tape : Tape) -> Unit raise {
  guard (if tape.format == "moonrobo.apic-audit-tape.v1" {
    self.format == "moonrobo.apic-sdk-oracle.v1"
  } else {
    self.format == "moonrobo.apic-sdk-oracle.v2" &&
    self.num_envs == Some(tape.num_envs) &&
    self.selected_worlds == tape.selected_worlds
  }) else {
    fail("SDK oracle tape version/world selection mismatch")
  }
  for snapshot in self.snapshots {
    validate_readback(snapshot.readback, tape.worlds().length())
  }
}

///|
fn validate_readback(value : @gpu.AuditReadback, count : Int32) -> Unit raise {
  guard rows_valid(value.state71, count, 71) &&
    rows_valid(value.root_pose, count, 7) &&
    rows_valid(value.root_com_velocity, count, 6) &&
    rows_valid(value.root_com_local, count, 3) &&
    rows_valid(value.joint_position, count, 29) &&
    rows_valid(value.joint_velocity, count, 29) &&
    rows_valid(value.torso_com, count, 3) &&
    value.shape_friction.length() == count &&
    value.shape_friction.all(row => {
      !row.is_empty() && row.length() <= 4096 && row.all(finite)
    }) &&
    !value.ground_friction.is_empty() &&
    value.ground_friction.length() <= 4096 &&
    value.ground_friction.all(finite) else {
    fail("audit readback dimensions/nonfinite/property bound mismatch")
  }
}
