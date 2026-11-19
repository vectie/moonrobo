///|
pub(all) enum GraphRole {
  Step
  Reset
  Context
  Refresh
} derive(Debug, Eq)

///|
pub fn GraphRole::name(self : GraphRole) -> String {
  match self {
    Step => "step"
    Reset => "reset"
    Context => "context"
    Refresh => "refresh"
  }
}

///|
pub(all) struct CapturedRegion {
  allocation : Allocation
  transient : Bool
} derive(Debug)

///|
/// The recorder supplies the regions/modules actually referenced by a graph.
/// This declaration alone never certifies that a kernel was captured/executed.
pub(all) struct GraphCapture {
  role : GraphRole
  regions : Array[CapturedRegion]
  module_keys : Array[String]
} derive(Debug)

///|
/// The one approved pointer-bearing allocation remains outside D2D numerical
/// synchronization. Its actual handles must be covered by official relocation.
pub(all) struct MeshHandles {
  allocation : Allocation
  owned : Bool
  contiguous : Bool
  handles : Array[UInt64]
  registered_mesh_ids : Array[UInt64]
} derive(Debug)

///|
pub fn MeshHandles::validate(self : MeshHandles) -> Unit raise ContractError {
  ignore(allocation_end(self.allocation))
  guard self.allocation.scalar_type == U64 &&
    self.allocation.capture_origin is None &&
    self.owned &&
    self.contiguous &&
    self.allocation.address % 8UL == 0UL else {
    raise Invalid(
      "mesh handles must own the entire immutable contiguous uint64 allocation",
    )
  }
  guard self.handles.length().to_int64() * 8L == self.allocation.bytes else {
    raise Invalid("mesh handle allocation includes unclassified trailing bytes")
  }
  let seen : Array[UInt64] = []
  for id in self.registered_mesh_ids {
    guard id != 0UL && !seen.contains(id) else {
      raise Invalid(
        "registered mesh identities must be unique nonnull actual Mesh handles",
      )
    }
    seen.push(id)
  }
  for id in self.handles {
    guard id == 0UL || seen.contains(id) else {
      raise Invalid(
        "mesh allocation contains an unknown opaque geometry handle",
      )
    }
  }
}

///|
/// Validate exactly one graph per original role. Scratch cannot become any
/// other graph's persistent input, nor alias the approved mesh allocation.
pub fn NumericUnion::build(
  initial : Array[Allocation],
  graphs : Array[GraphCapture],
  mesh? : MeshHandles,
) -> NumericUnion raise ContractError {
  guard graphs.length() == 4 else {
    raise Invalid("exactly step/reset/context/refresh captures are required")
  }
  if mesh is Some(value) {
    value.validate()
  }
  let regions : Array[NumericRegion] = []
  for allocation in initial {
    if mesh is Some(value) {
      guard disjoint(allocation, value.allocation) else {
        raise Invalid(
          "readonly mesh handles cannot be included in numerical union",
        )
      }
    }
    add_numeric(regions, allocation)
  }
  let roles : Array[GraphRole] = []
  let persistent : Array[Allocation] = initial.copy()
  let transient : Array[Allocation] = []
  for graph in graphs {
    guard !roles.contains(graph.role) else {
      raise Invalid("duplicate graph role")
    }
    roles.push(graph.role)
    let keys : Array[String] = []
    for key in graph.module_keys {
      guard !key.is_empty() && !key.contains("\u{0}") && !keys.contains(key) else {
        raise Invalid("invalid/duplicate captured module key")
      }
      keys.push(key)
    }
    for captured in graph.regions {
      let allocation = captured.allocation
      ignore(allocation_end(allocation))
      if allocation.capture_origin is Some(origin) {
        guard captured.transient && origin == graph.role.name() else {
          raise Invalid(
            "capture allocation origin disagrees with transient graph ownership",
          )
        }
      }
      if mesh is Some(value) {
        if allocation.address == value.allocation.address {
          guard !captured.transient && allocation == value.allocation else {
            raise Invalid(
              "readonly mesh base aliases incompatible or transient storage",
            )
          }
          continue
        }
        guard disjoint(allocation, value.allocation) else {
          raise Invalid("captured storage partially aliases mesh handles")
        }
      }
      if captured.transient {
        transient.push(allocation)
      } else {
        persistent.push(allocation)
        add_numeric(regions, allocation)
      }
    }
  }
  for scratch in transient {
    for base in persistent {
      guard disjoint(scratch, base) else {
        raise Invalid(
          "capture-scoped scratch escaped into persistent numerical inputs",
        )
      }
    }
  }
  guard !regions.is_empty() else {
    raise Invalid("capture has no persistent numerical union")
  }
  { regions, }
}

///|
/// Convenient entry for plugins which already expose typed allocation facts.
pub fn validate_regions(
  initial : Array[Allocation],
  graphs : Array[GraphCapture],
  mesh? : MeshHandles,
) -> NumericUnion raise ContractError {
  NumericUnion::build(initial, graphs, mesh?)
}
