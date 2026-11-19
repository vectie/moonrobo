///|
/// No global entities in the supported builder subset. Preserve the real
/// Newton world_count+2 format, including empty global-tail and total entries.
fn world_starts(ids : Array[Int32], worlds : Int32) -> Array[Int32] raise {
  guard worlds > 0 else { fail("invalid world count") }
  let counts = Array::make(worlds, 0)
  let mut previous = 0
  for id in ids {
    guard id >= 0 && id < worlds && id >= previous else {
      fail("noncontiguous or invalid world ownership")
    }
    previous = id
    counts[id] += 1
  }
  let starts = [0]
  for count in counts {
    starts.push(starts.last().unwrap() + count)
  }
  starts.push(ids.length())
  starts
}

///|
fn targets(
  types : Array[Int32],
  q_start : Array[Int32],
  qd_start : Array[Int32],
  q : Array[Double],
  target_layout : String,
) -> Array[Double] raise {
  guard target_layout == "coord" || target_layout == "dof" else {
    fail("target_layout must be coord or dof")
  }
  let size = if target_layout == "coord" {
    q.length()
  } else {
    qd_start.last().unwrap()
  }
  let result = Array::make(size, 0.0)
  for index, kind in types {
    let offset = if target_layout == "coord" {
      q_start[index]
    } else {
      qd_start[index]
    }
    if kind == 4 {
      // Free joints are unactuated. Coord-layout targets must still have a
      // valid quaternion; legacy DOF targets contain six zero axis targets.
      if target_layout == "coord" {
        result[offset + 6] = 1.0
      }
    } else if kind == 1 {
      result[offset] = q[q_start[index]]
    }
  }
  result
}

///|
fn validate_prepared(
  p : @builder.PreparedArrays,
) -> (Int32, Int32, Int32, Int32, Int32) raise {
  let nb = p.body_world.length()
  let nj = p.joint_type.length()
  let nq = p.joint_q.length()
  let nv = p.joint_qd.length()
  let nw = p.articulation_start.length()
  guard nb > 0 &&
    nj == nb &&
    nw > 0 &&
    p.articulation_end.length() == nw &&
    p.body_q.length() == nb * 7 &&
    p.body_qd.length() == nb * 6 &&
    p.body_mass_properties.length() == nb &&
    p.joint_world.length() == nj &&
    p.joint_parent.length() == nj &&
    p.joint_child.length() == nj &&
    p.joint_q_start.length() == nj + 1 &&
    p.joint_qd_start.length() == nj + 1 &&
    p.joint_axis_start.length() == nj + 1 &&
    p.joint_X_p.length() == nj * 7 &&
    p.joint_X_c.length() == nj * 7 &&
    p.joint_axis.length() == nv * 3 &&
    p.joint_armature.length() == nv &&
    p.joint_target_ke.length() == nv &&
    p.joint_target_kd.length() == nv &&
    p.joint_effort_limit.length() == nv &&
    p.joint_velocity_limit.length() == nv &&
    p.joint_limit_lower.length() == nv &&
    p.joint_limit_upper.length() == nv &&
    p.joint_q_start[0] == 0 &&
    p.joint_qd_start[0] == 0 &&
    p.joint_q_start[nj] == nq &&
    p.joint_qd_start[nj] == nv else {
    fail("prepared rigid-tree array cardinality mismatch")
  }
  let incoming = Array::make(nb, -1)
  for joint in 0..<nj {
    let (coords, dofs) = match p.joint_type[joint] {
      4 => (7, 6)
      1 => (1, 1)
      3 => (0, 0)
      _ => fail("unsupported prepared joint type")
    }
    guard p.joint_q_start[joint + 1] - p.joint_q_start[joint] == coords &&
      p.joint_qd_start[joint + 1] - p.joint_qd_start[joint] == dofs &&
      p.joint_axis_start[joint] == p.joint_qd_start[joint] &&
      p.joint_axis_start[joint + 1] == p.joint_qd_start[joint + 1] else {
      fail("prepared coordinate/DOF offsets disagree with joint types")
    }
    let parent = p.joint_parent[joint]
    let child = p.joint_child[joint]
    let world = p.joint_world[joint]
    guard child >= 0 &&
      child < nb &&
      incoming[child] == -1 &&
      world >= 0 &&
      world < nw &&
      p.body_world[child] == world &&
      (
        (parent == -1 && p.joint_type[joint] == 4) ||
        (parent >= 0 && parent < child && p.body_world[parent] == world)
      ) else {
      fail("invalid tree parent/child/world ownership")
    }
    incoming[child] = joint
  }
  guard incoming.all(x => x >= 0) else {
    fail("a rigid body has no incoming tree/base joint")
  }
  let starts = world_starts(p.joint_world, nw)
  for world in 0..<nw {
    guard p.articulation_start[world] == starts[world] &&
      p.articulation_end[world] == starts[world + 1] &&
      starts[world] < starts[world + 1] &&
      p.joint_type[starts[world]] == 4 else {
      fail("articulation ownership does not match contiguous worlds")
    }
  }
  (nb, nj, nq, nv, nw)
}

///|
/// Compute the host arrays used by the supported model/state/control subset.
/// Buffer names deliberately match corresponding Newton fields where their
/// scope and semantics match, without constructing a Python/C++ Newton object.
pub fn prepare_arrays(
  p : @builder.PreparedArrays,
  scalar_type : String,
  target_layout : String,
) -> HostLayout raise {
  guard scalar_type == "f32" || scalar_type == "f64" else {
    fail("scalar_type must be f32 or f64")
  }
  let (nb, nj, nq, nv, nw) = validate_prepared(p)
  let arrays : Map[String, HostArray] = {}
  fn ints(
    name : String,
    data : Array[Int32],
    shape : Array[Int32],
  ) -> Unit raise {
    arrays[name] = integers(data, shape)
  }
  fn floats(
    name : String,
    data : Array[Double],
    shape : Array[Int32],
  ) -> Unit raise {
    let count = array_count(shape, 1)
    guard count > 0 && data.length() % count == 0 else {
      fail("invalid scalar/vector array cardinality")
    }
    arrays[name] = floating(
      data,
      shape,
      scalar_type,
      components=data.length() / count,
    )
  }
  let body_starts = world_starts(p.body_world, nw)
  let joint_starts = world_starts(p.joint_world, nw)
  ints("model.body_world", p.body_world, [nb])
  ints("model.body_world_start", body_starts, [nw + 2])
  ints("model.body_flags", Array::make(nb, 1), [nb]) // pinned BodyFlags.DYNAMIC
  ints("model.joint_type", p.joint_type, [nj])
  ints("model.joint_parent", p.joint_parent, [nj])
  ints("model.joint_child", p.joint_child, [nj])
  ints("model.joint_world", p.joint_world, [nj])
  ints("model.joint_world_start", joint_starts, [nw + 2])
  ints("model.joint_q_start", p.joint_q_start, [nj + 1])
  ints("model.joint_qd_start", p.joint_qd_start, [nj + 1])
  ints(
    "model.joint_coord_world_start",
    joint_starts.map(i => p.joint_q_start[i]),
    [nw + 2],
  )
  ints(
    "model.joint_dof_world_start",
    joint_starts.map(i => p.joint_qd_start[i]),
    [nw + 2],
  )
  let dof_dim = []
  let target_mode = []
  let ancestors = []
  let membership = []
  let incoming = Array::make(nb, -1)
  for joint, child in p.joint_child {
    incoming[child] = joint
  }
  for joint, kind in p.joint_type {
    dof_dim.append(
      match kind {
        4 => [3, 3]
        1 => [0, 1]
        _ => [0, 0]
      },
    )
    ancestors.push(
      if p.joint_parent[joint] < 0 {
        -1
      } else {
        incoming[p.joint_parent[joint]]
      },
    )
    membership.push(p.joint_world[joint])
  }
  for dof in 0..<nv {
    target_mode.push(
      if p.joint_target_ke[dof] != 0.0 {
        1
      } else if p.joint_target_kd[dof] != 0.0 {
        2
      } else {
        0
      },
    )
  }
  ints("model.joint_dof_dim", dof_dim, [nj, 2])
  ints("model.joint_ancestor", ancestors, [nj])
  ints("model.joint_articulation", membership, [nj])
  ints("model.joint_target_mode", target_mode, [nv])
  let articulation_start = p.articulation_start.copy()
  articulation_start.push(nj)
  ints("model.articulation_start", articulation_start, [nw + 1])
  ints("model.articulation_end", p.articulation_end, [nw])
  ints("model.articulation_world", Array::makei(nw, i => i), [nw])
  ints(
    "model.articulation_world_start",
    Array::makei(nw + 2, i => if i < nw { i } else { nw }),
    [nw + 2],
  )
  floats("model.body_q", p.body_q, [nb])
  floats("model.body_qd", p.body_qd, [nb])
  floats("model.joint_X_p", p.joint_X_p, [nj])
  floats("model.joint_X_c", p.joint_X_c, [nj])
  floats("model.joint_axis", p.joint_axis, [nv])
  floats("model.joint_q", p.joint_q, [nq])
  floats("model.joint_qd", p.joint_qd, [nv])
  for
    (name, data) in [
      ("joint_armature", p.joint_armature),
      ("joint_target_ke", p.joint_target_ke),
      ("joint_target_kd", p.joint_target_kd),
      ("joint_effort_limit", p.joint_effort_limit),
      ("joint_velocity_limit", p.joint_velocity_limit),
    ] {
    floats("model." + name, data, [nv])
  }
  // Actual pinned Newton MAXVAL from core/types.py, rather than IEEE infinity.
  floats(
    "model.joint_limit_lower",
    p.joint_limit_lower.map(x => x.unwrap_or(-1.0e10)),
    [nv],
  )
  floats(
    "model.joint_limit_upper",
    p.joint_limit_upper.map(x => x.unwrap_or(1.0e10)),
    [nv],
  )
  arrays["model.joint_enabled"] = {
    scalar_type: "bool",
    shape: [nj],
    components: 1,
    bytes: Bytes::from_array(Array::make(nj, 1)),
  }
  let target = targets(
    p.joint_type,
    p.joint_q_start,
    p.joint_qd_start,
    p.joint_q,
    target_layout,
  )
  let target_count = target.length()
  ints(
    "model.joint_target_q_start",
    if target_layout == "coord" {
      p.joint_q_start
    } else {
      p.joint_qd_start
    },
    [nj + 1],
  )
  for prefix in ["model", "control"] {
    floats(prefix + ".joint_target_q", target, [target_count])
    floats(prefix + ".joint_target_qd", Array::make(nv, 0.0), [nv])
    floats(prefix + ".joint_f", Array::make(nv, 0.0), [nv])
    floats(prefix + ".joint_act", Array::make(nv, 0.0), [nv])
  }
  for prefix in ["state0", "state1"] {
    floats(prefix + ".body_q", p.body_q, [nb])
    floats(prefix + ".body_qd", p.body_qd, [nb])
    floats(prefix + ".body_f", Array::make(nb * 6, 0.0), [nb])
    floats(prefix + ".joint_q", p.joint_q, [nq])
    floats(prefix + ".joint_qd", p.joint_qd, [nv])
  }
  let mass_complete = p.body_mass_properties.all(x => x is Some(_))
  if mass_complete {
    let mass = []
    let inv_mass = []
    let com = []
    let inertia = []
    let inv_inertia = []
    for entry in p.body_mass_properties {
      let body = entry.unwrap()
      guard body.mass > 0.0 &&
        body.inverse_mass > 0.0 &&
        body.center_of_mass.length() == 3 &&
        body.inertia.length() == 9 &&
        body.inverse_inertia.length() == 9 else {
        fail("invalid complete authored body inertia")
      }
      mass.push(body.mass)
      inv_mass.push(body.inverse_mass)
      com.append(body.center_of_mass)
      inertia.append(body.inertia)
      inv_inertia.append(body.inverse_inertia)
    }
    floats("model.body_mass", mass, [nb])
    floats("model.body_inv_mass", inv_mass, [nb])
    floats("model.body_com", com, [nb])
    floats("model.body_inertia", inertia, [nb])
    floats("model.body_inv_inertia", inv_inertia, [nb])
  }
  let unresolved = p.unresolved_semantics.copy()
  unresolved.append([
    "layout is a rigid-tree model/state/control subset, not a finalized Newton Model or SolverMuJoCo input",
    "particle/shape/contact/constraint/cooking/resolver/custom state and solver namespace buffers are absent",
    "target modes use default from_gains semantics; explicit authored modes and force_position_velocity overrides are not applied",
    "f32 bytes are checked CPU Double conversions; upstream float32 correction/evaluation order is not equivalent by assertion",
  ])
  if !mass_complete {
    unresolved.push(
      "authored mass properties are incomplete: body_mass/COM/inertia buffers are absent, not filled with guessed values",
    )
  }
  {
    arrays,
    aliases: {},
    storage_scope: { "kind": "rigid-tree-model-state-control-subset" },
    body_count: nb,
    joint_count: nj,
    coord_count: nq,
    dof_count: nv,
    world_count: nw,
    scalar_type,
    target_layout,
    mass_properties_complete: mass_complete,
    unresolved_semantics: unresolved,
  }
}

///|
pub fn prepare(request : CommandRequest) -> HostLayout raise {
  prepare_arrays(
    @builder.prepare_from_receipt(request.builder_request),
    request.scalar_type,
    request.target_layout,
  )
}
