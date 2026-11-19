///|
/// Actual pinned island.py tree-order active packing, computed on the host.
/// The resulting bytes are immutable imported inputs for one native program;
/// this is not a dynamic GPU sleep/compaction producer inside graph replay.
pub(all) struct ActiveMapRequest {
  nworld : Int32
  nv : Int32
  nvmax : Int32
  nvmax_pad : Int32
  tree_dofadr : Array[Int32]
  tree_dofnum : Array[Int32]
  tree_awake : Array[Array[Int32]]
  overflow : Array[Int32]
} derive(FromJson, ToJson)

///|
fn packed_ints(values : Array[Int32]) -> Bytes {
  Bytes::makei(values.length() * 4, i => {
    (values[i / 4].reinterpret_as_uint() >> (i % 4 * 8)).to_byte()
  })
}

///|
/// Returns actual ncdof/dof_cdof/cdof_dof/overflow buffers. Overflow retains
/// previous bits and ORs NVMAX=128 exactly, while the active count is capped.
/// It must be gated by the caller; a capped map is not a successful full solve.
pub fn build_active_maps(r : ActiveMapRequest) -> Array[Workspace] raise {
  guard r.nworld > 0 &&
    r.nv >= 0 &&
    r.nvmax >= 0 &&
    r.nvmax <= r.nv &&
    r.nvmax_pad >= r.nvmax &&
    r.tree_dofadr.length() == r.tree_dofnum.length() &&
    r.tree_awake.length() == r.nworld &&
    r.overflow.length() == r.nworld &&
    r.nworld <= 2147483647 / 4 &&
    (r.nv == 0 || r.nworld <= 2147483647 / 4 / r.nv) &&
    (r.nvmax_pad == 0 || r.nworld <= 2147483647 / 4 / r.nvmax_pad) else {
    fail("invalid active map input shape")
  }
  let seen : Map[Int32, Unit] = {}
  for t in 0..<r.tree_dofadr.length() {
    let adr = r.tree_dofadr[t]
    let num = r.tree_dofnum[t]
    guard adr >= 0 && adr <= r.nv && num >= 0 && num <= r.nv - adr else {
      fail("actual tree DOF interval out of range")
    }
    for d in adr..<(adr + num) {
      guard !seen.contains(d) else { fail("actual tree DOF intervals overlap") }
      seen[d] = ()
    }
  }
  guard seen.length() == r.nv else {
    fail("actual tree DOF intervals must cover full DOF space")
  }
  let full = Array::make(r.nworld * r.nv, -1)
  let compact = Array::make(r.nworld * r.nvmax_pad, -1)
  let counts = Array::make(r.nworld, 0)
  let overflow = r.overflow.copy()
  for w in 0..<r.nworld {
    guard r.tree_awake[w].length() == r.tree_dofadr.length() && overflow[w] >= 0 else {
      fail("actual awake or overflow row shape/domain invalid")
    }
    let mut count = 0
    for t in 0..<r.tree_dofadr.length() {
      if r.tree_awake[w][t] == 1 {
        for j in 0..<r.tree_dofnum[t] {
          let d = r.tree_dofadr[t] + j
          if count < r.nvmax {
            full[w * r.nv + d] = count
            compact[w * r.nvmax_pad + count] = d
          }
          count += 1
        }
      }
    }
    if count > r.nvmax {
      overflow[w] = overflow[w] | 128
      counts[w] = r.nvmax
    } else {
      counts[w] = count
    }
  }
  [
    {
      name: "ncdof",
      scalar_type: "int32",
      shape: [r.nworld],
      bytes: packed_ints(counts),
      initialization: "actual-tree-order-host-compaction",
    },
    {
      name: "dof_cdof",
      scalar_type: "int32",
      shape: [r.nworld, r.nv],
      bytes: packed_ints(full),
      initialization: "actual-tree-order-host-compaction",
    },
    {
      name: "cdof_dof",
      scalar_type: "int32",
      shape: [r.nworld, r.nvmax_pad],
      bytes: packed_ints(compact),
      initialization: "actual-tree-order-host-compaction",
    },
    {
      name: "overflow",
      scalar_type: "int32",
      shape: [r.nworld],
      bytes: packed_ints(overflow),
      initialization: "retained-bits-or-real-NVMAX-overflow",
    },
  ]
}
