///|
/// Actual occupancy of one already-specialized upstream CCD kernel. Obtain
/// these numbers from Kernel.suggested_block_size on that kernel; this record
/// itself neither loads a module nor queries a device.
pub(all) struct Occupancy {
  geom1 : Int32
  geom2 : Int32
  block_size : Int32
  min_grid_size : Int32
} derive(FromJson, ToJson, Debug)

///|
pub(all) struct GeomPair {
  geom1 : Int32
  geom2 : Int32
} derive(FromJson, ToJson, Debug)

///|
/// Inputs to the pinned 3.15 convex_narrowphase host algorithm. Pair counts
/// are the actual 66-entry upper triangle for the eleven-member GeomType;
/// the table retains its original order. use_multiccd is the resolved actual
/// disable-flag value, not a guessed bit number. Occupancy belongs to the
/// corresponding actual per-pair upstream kernel, not the generic contacts
/// entry emitted by lower(Request).
pub(all) struct HostScheduleRequest {
  collision_table : Array[GeomPair]
  geom_pair_type_count : Array[Int32]
  naconmax : Int32
  naccdmax : Int32
  ccd_iterations : Int32
  model_npolygonmax : Int32
  model_nmeshdegmax : Int32
  use_multiccd : Bool
  warn_overflow : Int32
  is_cpu : Bool
  convex_block_dim : Int32
  occupancy : Array[Occupancy]
} derive(FromJson, ToJson, Debug)

///|
pub(all) struct ScratchAllocation {
  name : String
  dtype : String
  shape : Array[Int32]
  bytes : Int64
  zero_initialize : Bool
  phase : String
} derive(ToJson, Debug)

///|
pub(all) struct PlannedPairLaunch {
  geom1 : Int32
  geom2 : Int32
  geomgeomid : Int32
  pair_count : Int32
  kernel_builder : String
  dimension : Int32
  block_dim : Int32
  gjk_iterations : Int32
  epa_iterations : Int32
  use_multiccd : Bool
  warn_overflow : Int32
} derive(ToJson, Debug)

///|
pub(all) struct HostSchedule {
  source_callable : String
  ncollision : Int32
  epa_iterations : Int32
  npolygonmax : Int32
  nmeshdegmax : Int32
  scratch : Array[ScratchAllocation]
  launches : Array[PlannedPairLaunch]
} derive(ToJson, Debug)

///|
/// Pinned _ccd_grid_size, with actual occupancy supplied by the caller. The
/// checked Int64 product preserves the formula without intermediate Int wrap.
/// No runtime/device operation takes place here. CPU ignores occupancy.
pub fn ccd_grid_size(
  naconmax : Int32,
  is_cpu : Bool,
  block_size : Int32,
  min_grid_size : Int32,
) -> Int32 raise {
  guard naconmax >= 0 else { raise Unsupported::Invalid("negative naconmax") }
  if is_cpu {
    return naconmax
  }
  guard block_size > 0 && block_size <= 1024 && min_grid_size > 0 else {
    raise Unsupported::Invalid("actual positive CUDA occupancy required")
  }
  let waves = 2L * block_size.to_int64() * min_grid_size.to_int64()
  let capped = if waves < naconmax.to_int64() {
    waves
  } else {
    naconmax.to_int64()
  }
  if capped < 1 {
    1
  } else {
    capped.to_int()
  }
}

///|
fn schedule_pair_index(g1 : Int32, g2 : Int32) -> Int32 {
  // math.upper_trid_index(11,g1,g2); source table is already type-ordered.
  g1 * (22 - g1 - 1) / 2 + g2
}

///|
fn schedule_int(value : Int64, what : String) -> Int32 raise {
  guard value >= 0 && value <= 2147483647L else {
    raise Unsupported::Invalid(what + " exceeds actual int32 layout")
  }
  value.to_int()
}

///|
fn schedule_allocation(
  name : String,
  dtype : String,
  shape : Array[Int32],
  width : Int64,
  phase : String,
  zero_initialize~ : Bool = false,
) -> ScratchAllocation raise {
  let mut bytes = width
  for dimension in shape {
    guard dimension >= 0 else {
      raise Unsupported::Invalid("negative scratch dimension: " + name)
    }
    guard dimension == 0 || bytes <= 9223372036854775807L / dimension.to_int64() else {
      raise Unsupported::Invalid("scratch byte footprint overflow: " + name)
    }
    bytes *= dimension.to_int64()
  }
  { name, dtype, shape, bytes, phase, zero_initialize, }
}

///|
/// Translates the actual pinned host schedule and allocation math. This does
/// not allocate device memory or execute kernels. The returned per-type
/// upstream builders are deliberately distinct from lower(Request)'s single
/// generic terminal contact entry and its fixed launch policy/scratch ABI.
/// Hfield launches precede all rigid launches; order within each group is the
/// original table order. Unsupported deformable/SDF providers fail closed.
pub fn plan_host_schedule(request : HostScheduleRequest) -> HostSchedule raise {
  guard request.geom_pair_type_count.length() == 66 else {
    raise Unsupported::Invalid(
      "actual eleven-type upper triangle requires 66 counts",
    )
  }
  guard request.naconmax >= 0 &&
    request.naccdmax >= 0 &&
    request.ccd_iterations > 0 &&
    request.model_npolygonmax >= 0 &&
    request.model_nmeshdegmax >= 0 &&
    request.warn_overflow >= 0 &&
    request.convex_block_dim > 0 &&
    request.convex_block_dim <= 1024 else {
    raise Unsupported::Invalid(
      "invalid actual host/model capacities or block dimension",
    )
  }
  for count in request.geom_pair_type_count {
    guard count >= 0 else {
      raise Unsupported::Invalid("negative actual geom pair count")
    }
  }
  let seen : Array[Int32] = []
  let mut count = 0L
  let mut has_boxbox = false
  let mut nqueried = 0
  for pair in request.collision_table {
    guard pair.geom1 >= 1 &&
      pair.geom1 <= pair.geom2 &&
      pair.geom2 <= 7 &&
      !(pair.geom1 == 1 && pair.geom2 == 1) else {
      raise Unsupported::Invalid(
        "host CCD table requires ordered hfield/rigid convex pairs; plane, SDF and deformable providers are separate",
      )
    }
    let index = schedule_pair_index(pair.geom1, pair.geom2)
    guard !seen.contains(index) else {
      raise Unsupported::Invalid("duplicate type pair in collision table")
    }
    seen.push(index)
    count += request.geom_pair_type_count[index].to_int64()
    if pair.geom1 == 6 && pair.geom2 == 6 {
      has_boxbox = true
    }
    if pair.geom1 != 1 && request.geom_pair_type_count[index] > 0 {
      nqueried += 1
    }
  }
  let ncollision = schedule_int(count, "collision pair count")
  if ncollision == 0 {
    return {
      source_callable: "collision_convex.convex_narrowphase",
      ncollision,
      epa_iterations: 0,
      npolygonmax: 0,
      nmeshdegmax: 0,
      scratch: [],
      launches: [],
    }
  }
  guard request.naconmax > 0 && request.naccdmax > 0 else {
    raise Unsupported::Invalid(
      "active collision table requires positive actual candidate/scratch capacities",
    )
  }
  if !request.is_cpu {
    guard request.occupancy.length() == nqueried else {
      raise Unsupported::Invalid(
        "one actual occupancy query per active non-heightfield pair required",
      )
    }
    let queried : Array[Int32] = []
    for occupancy in request.occupancy {
      guard occupancy.geom1 >= 2 &&
        occupancy.geom1 <= occupancy.geom2 &&
        occupancy.geom2 <= 7 else {
        raise Unsupported::Invalid("invalid occupancy type pair")
      }
      let index = schedule_pair_index(occupancy.geom1, occupancy.geom2)
      guard seen.contains(index) &&
        request.geom_pair_type_count[index] > 0 &&
        !queried.contains(index) else {
        raise Unsupported::Invalid(
          "occupancy must match each active actual kernel exactly once",
        )
      }
      ignore(
        ccd_grid_size(
          request.naconmax,
          false,
          occupancy.block_size,
          occupancy.min_grid_size,
        ),
      )
      queried.push(index)
    }
  } else {
    guard request.occupancy.is_empty() else {
      raise Unsupported::Invalid(
        "CPU host plan does not consume CUDA occupancy",
      )
    }
  }
  let counts = request.geom_pair_type_count
  let nboxbox = if has_boxbox { counts[schedule_pair_index(6, 6)] } else { 0 }
  let nboxmesh = counts[schedule_pair_index(6, 7)]
  let nmeshmesh = counts[schedule_pair_index(7, 7)]
  let ncylcyl = counts[schedule_pair_index(5, 5)]
  let ncylbox = counts[schedule_pair_index(5, 6)]
  let ncylmesh = counts[schedule_pair_index(5, 7)]
  let epa_iterations = if nboxbox == ncollision {
    16
  } else {
    request.ccd_iterations
  }
  let mut npolygonmax = if nboxbox > 0 { 4 } else { 0 }
  let mut nmeshdegmax = if nboxbox > 0 { 3 } else { 0 }
  if request.use_multiccd && (ncylcyl > 0 || ncylbox > 0 || ncylmesh > 0) {
    npolygonmax = request.model_npolygonmax.max(16)
    nmeshdegmax = request.model_nmeshdegmax.max(3)
  } else if request.use_multiccd && (nmeshmesh > 0 || nboxmesh > 0) {
    let minval = if nboxmesh > 0 { 4 } else { npolygonmax }
    npolygonmax = request.model_npolygonmax.max(minval)
    nmeshdegmax = request.model_nmeshdegmax.max(3)
  }
  let epa_vertices = schedule_int(
    10L + 2L * epa_iterations.to_int64(),
    "EPA vertex row",
  )
  let epa_faces = schedule_int(
    6L + 5L * epa_iterations.to_int64(),
    "EPA face row",
  )
  let polygon_double = schedule_int(
    2L * npolygonmax.to_int64(),
    "clipped polygon row",
  )
  let scratch = [
    schedule_allocation(
      "nccd",
      "int32",
      [66],
      4L,
      "before_heightfield",
      zero_initialize=true,
    ),
  ]
  for
    (name, dtype, width) in [
      ("epa_vert", "vec3f", 12L),
      ("epa_vert_index", "int32", 4L),
    ] {
    scratch.push(
      schedule_allocation(
        name,
        dtype,
        [request.naccdmax, epa_vertices],
        width,
        "before_heightfield",
      ),
    )
  }
  for
    (name, dtype, width) in [
      ("epa_face", "int32", 4L),
      ("epa_pr", "vec3f", 12L),
      ("epa_norm2", "float32", 4L),
    ] {
    scratch.push(
      schedule_allocation(
        name,
        dtype,
        [request.naccdmax, epa_faces],
        width,
        "before_heightfield",
      ),
    )
  }
  scratch.push(
    schedule_allocation(
      "epa_horizon",
      "int32",
      [request.naccdmax, 24],
      4L,
      "before_heightfield",
    ),
  )
  for
    (name, dtype, row, width) in [
      ("multiccd_polygon", "vec3f", polygon_double, 12L),
      ("multiccd_clipped", "vec3f", polygon_double, 12L),
      ("multiccd_pnormal", "vec3f", npolygonmax, 12L),
      ("multiccd_pdist", "float32", npolygonmax, 4L),
      ("multiccd_idx1", "int32", nmeshdegmax, 4L),
      ("multiccd_idx2", "int32", nmeshdegmax, 4L),
      ("multiccd_n1", "vec3f", nmeshdegmax, 12L),
      ("multiccd_n2", "vec3f", nmeshdegmax, 12L),
      ("multiccd_endvert", "vec3f", nmeshdegmax, 12L),
      ("multiccd_face1", "vec3f", npolygonmax, 12L),
      ("multiccd_face2", "vec3f", npolygonmax, 12L),
    ] {
    scratch.push(
      schedule_allocation(
        name,
        dtype,
        [request.naccdmax, row],
        width,
        "after_heightfield_before_rigid",
      ),
    )
  }
  let launches : Array[PlannedPairLaunch] = []
  for heightfield in [true, false] {
    for pair in request.collision_table {
      let index = schedule_pair_index(pair.geom1, pair.geom2)
      let pair_count = counts[index]
      if (pair.geom1 == 1) == heightfield && pair_count > 0 {
        let mut dimension = request.naconmax
        if !heightfield && !request.is_cpu {
          // Exact one-to-one query matching was established above.
          for occupancy in request.occupancy {
            if occupancy.geom1 == pair.geom1 && occupancy.geom2 == pair.geom2 {
              dimension = ccd_grid_size(
                request.naconmax,
                false,
                occupancy.block_size,
                occupancy.min_grid_size,
              )
              break
            }
          }
        }
        launches.push({
          geom1: pair.geom1,
          geom2: pair.geom2,
          geomgeomid: index,
          pair_count,
          kernel_builder: if heightfield {
            "ccd_hfield_kernel_builder"
          } else {
            "ccd_kernel_builder"
          },
          dimension,
          // Upstream hfield passes no block_dim. Zero explicitly denotes that
          // unresolved/default policy; CPU Warp forces one in either branch.
          block_dim: if request.is_cpu {
            1
          } else if heightfield {
            0
          } else {
            request.convex_block_dim
          },
          gjk_iterations: request.ccd_iterations,
          epa_iterations,
          use_multiccd: !heightfield && request.use_multiccd,
          warn_overflow: request.warn_overflow,
        })
      }
    }
  }
  {
    source_callable: "collision_convex.convex_narrowphase",
    ncollision,
    epa_iterations,
    npolygonmax,
    nmeshdegmax,
    scratch,
    launches,
  }
}
