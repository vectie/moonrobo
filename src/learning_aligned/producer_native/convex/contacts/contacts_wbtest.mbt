///|
fn sample_request() -> Request {
  {
    nworld: 2,
    ngeom: 3,
    candidate_capacity: 4,
    contact_capacity: 16,
    vertex_capacity: 8,
    graph_capacity: 0,
    hfield_capacity: 0,
    hfield_data_capacity: 0,
    polygon_capacity: 6,
    polygon_vertex_capacity: 24,
    polygon_map_capacity: 24,
    efc_slots: 4,
    gjk_iterations: 32,
    epa_iterations: 64,
    epa_vertices: 64,
    epa_faces: 128,
    epa_horizon: 64,
    max_polygon_vertices: 16,
    tolerance: 1.0e-6,
    use_multiccd: true,
  }
}

///|
fn sample_schedule() -> HostScheduleRequest {
  let counts = Array::make(66, 0)
  counts[schedule_pair_index(6, 6)] = 3
  {
    collision_table: [{ geom1: 6, geom2: 6, }],
    geom_pair_type_count: counts,
    naconmax: 1024,
    naccdmax: 32,
    ccd_iterations: 64,
    model_npolygonmax: 7,
    model_nmeshdegmax: 5,
    use_multiccd: false,
    warn_overflow: 0,
    is_cpu: true,
    convex_block_dim: 128,
    occupancy: [],
  }
}

///|
test "host schedule preserves box-only EPA and scratch layout" {
  let plan = plan_host_schedule(sample_schedule())
  assert_eq(plan.epa_iterations, 16)
  assert_eq(plan.npolygonmax, 4)
  assert_eq(plan.nmeshdegmax, 3)
  assert_eq(plan.launches[0].block_dim, 1)
  assert_eq(plan.scratch[1].shape, [32, 42])
}

///|
test "host occupancy uses actual two-wave cap" {
  assert_eq(ccd_grid_size(10000, false, 128, 4), 1024)
  assert_eq(ccd_grid_size(7, false, 128, 4), 7)
  assert_eq(ccd_grid_size(0, false, 128, 4), 1)
  assert_eq(ccd_grid_size(0, true, 0, 0), 0)
}

///|
test "host hfield launch precedes table-ordered rigid launches" {
  let original = sample_schedule()
  let counts = original.geom_pair_type_count.copy()
  counts[schedule_pair_index(1, 6)] = 2
  let plan = plan_host_schedule({
    ..original,
    collision_table: [{ geom1: 6, geom2: 6, }, { geom1: 1, geom2: 6, }],
    geom_pair_type_count: counts,
  })
  assert_eq(plan.launches[0].geom1, 1)
  assert_eq(plan.launches[1].geom1, 6)
  assert_eq(plan.epa_iterations, 64)
}

///|
test "host zero-count return does not require actual occupancy" {
  let original = sample_schedule()
  let plan = plan_host_schedule({
    ..original,
    geom_pair_type_count: Array::make(66, 0),
    is_cpu: false,
    naconmax: 0,
    naccdmax: 0,
  })
  assert_true(plan.launches.is_empty())
  assert_true(plan.scratch.is_empty())
}

///|
test "completed contact gate rejects overflow and every failure category" {
  let request = sample_request()
  validate_results(request, 4, 16, Array::make(8, 0))
  for reason in 0..<8 {
    let counters = Array::make(8, 0)
    counters[reason] = 1
    try validate_results(request, 4, 16, counters) catch {
      _ => ()
    } noraise {
      _ => fail("failed contact result published")
    }
  }
  try validate_results(request, 4, 17, Array::make(8, 0)) catch {
    _ => ()
  } noraise {
    _ => fail("contact overflow published")
  }
}

///|
test "native vec3 scratch rejects overlapping candidate rows" {
  let param = parameter("epa_vert_in", "vec3f", 2, "scratch")
  let view : Binding = {
    name: "epa_vert_in",
    allocation: "scratch",
    dtype: "vec3f",
    shape: [2, 3],
    byte_strides: [32, 12],
    byte_offset: 0L,
    buffer_bytes: 80L,
  }
  try extent(view, param) catch {
    _ => ()
  } noraise {
    _ => fail("overlapping scratch rows accepted")
  }
  ignore(extent({ ..view, byte_strides: [36, 12], }, param))
}

///|
test "native compound views require full reachable byte extent" {
  let param = parameter("contact_frame_out", "mat33f", 1, "output")
  let view : Binding = {
    name: "contact_frame_out",
    allocation: "frames",
    dtype: "mat33f",
    shape: [2],
    byte_strides: [36],
    byte_offset: 4L,
    buffer_bytes: 75L,
  }
  try extent(view, param) catch {
    _ => ()
  } noraise {
    _ => fail("one byte beyond owner accepted")
  }
  ignore(extent({ ..view, buffer_bytes: 76L, }, param))
}

///|
test "request preserves explicit finite scratch and counter bounds" {
  let base = sample_request()
  for
    r in [
      { ..base, max_polygon_vertices: 15, },
      { ..base, epa_vertices: 1025, },
      { ..base, contact_capacity: 2147483647, },
      { ..base, graph_capacity: -1, },
    ] {
    try validate_request(r) catch {
      _ => ()
    } noraise {
      _ => fail("invalid contact specialization accepted")
    }
  }
}
