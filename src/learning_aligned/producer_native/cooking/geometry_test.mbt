///|
// Pending numerical/regression sources. Typechecking is permitted; none of
// these algorithms/tests were executed during this migration.
test "tetrahedron signed moments retain COM and offdiagonal inertia" {
  let mesh = @cooking.prepare_mesh({
    vertices: [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1],
    indices: [0, 2, 1, 0, 1, 3, 0, 3, 2, 1, 2, 3],
    velocities: [],
    groups: [],
    bvh_constructor: "sah",
    bvh_leaf_size: 4,
    support_winding_number: false,
  })
  let mass = @cooking.mesh_mass(mesh, 1, true, [])
  assert_true((mass.mass - 1.0 / 6).abs() < 1.0e-14)
  assert_eq(mass.com, [0.25, 0.25, 0.25])
  assert_true((mass.inertia[0] - 1.0 / 80).abs() < 1.0e-14)
  assert_true((mass.inertia[1] - 1.0 / 480).abs() < 1.0e-14)
  let rigid = @cooking.transform_mass(mass, [1, 0, 0, 0, 1, 0, 0, 0, 1], [
    2, -3, 4,
  ])
  assert_eq(rigid.com, [2.25, -2.75, 4.25])
  assert_eq(rigid.inertia, mass.inertia)
  let origin_tensor = @cooking.transform_inertia(
    mass.mass,
    mass.inertia,
    [2, 0, 0],
    [1, 0, 0, 0, 1, 0, 0, 0, 1],
  )
  assert_true(
    (origin_tensor[4] - mass.inertia[4] - mass.mass * 4).abs() < 1.0e-14,
  )
}

///|
test "primitive shell and cone COM are authored analytic properties" {
  let sphere = @cooking.primitive_mass("sphere", [2, 0, 0], 3, false, 0.5)
  let expected = 3.0 * 4 / 3 * 3.141592653589793 * (8 - 3.375)
  assert_true((sphere.mass - expected).abs() < 1.0e-12)
  let cone = @cooking.primitive_mass("cone", [2, 3, 0], 1, true, 0)
  assert_eq(cone.com, [0, 0, -1.5])
}

///|
test "signed scale reflection can preserve source SDF indices explicitly" {
  let mesh = @cooking.prepare_mesh(triangle_request())
  let outward = @cooking.bake_scale(mesh, [-1, 1, 1])
  let raw = @cooking.bake_scale(mesh, [-1, 1, 1], preserve_winding=true)
  assert_eq(outward.triangles(), [0, 2, 1])
  assert_eq(raw.triangles(), [0, 1, 2])
  assert_eq(raw.vertices(), [0, 0, 0, -1, 0, 0, 0, 1, 0])
}

///|
test "zero edge boxes retain complete filtered boundary set" {
  let mesh = @cooking.prepare_mesh(triangle_request())
  let original = @cooking.mesh_topology(mesh, 0).edges
  assert_eq(@cooking.absorb_edges(mesh, 0, 1, 0, 0.01), original)
  assert_eq(@cooking.absorb_edges(mesh, 0, 1, 0.01, 0), original)
}

///|
fn sdf_options(format : String) -> @cooking.SdfOptions {
  {
    margin: 0,
    narrow_band: [-10, 10],
    max_resolution: 16,
    target_voxel_size: None,
    texture_format: format,
    paired_samples: true,
    sign_method: "explicit-callback",
    linearization_error: Some(0),
  }
}

///|
test "unused quantized texture padding is integer zero with paired X" {
  let sdf = @cooking.build_sparse_sdf(
    [0, 0, 0],
    [2, 1, 1],
    sdf_options("uint16"),
    points => {
      Array::makei(points.length() / 3, i => points[i * 3] * points[i * 3])
    },
  )
  assert_eq(sdf.required_count, 2)
  assert_eq(sdf.texture_size, 18)
  // Two slots occupy (0,0,0) and (1,0,0); the y=9 row is unused.
  let offset = 9 * 18 * 2 * 2
  assert_eq(sdf.subgrid[offset], 0)
  assert_eq(sdf.subgrid[offset + 1], 0)
  assert_eq(sdf.subgrid[offset + 2], 0)
  assert_eq(sdf.subgrid[offset + 3], 0)
  sdf.validate_storage()
}

///|
test "software SDF value gradient extrapolation and margin" {
  let sdf = @cooking.build_sparse_sdf(
    [0, 0, 0],
    [2, 1, 1],
    sdf_options("float32"),
    points => Array::makei(points.length() / 3, i => points[i * 3]),
  )
  assert_eq(sdf.sample([0.25, 0.5, 0.5]), 0.25)
  assert_eq(sdf.sample_voxel([2, 4, 4]), 0.25)
  let inside = sdf.sample_gradient([0.25, 0.5, 0.5])
  assert_eq(inside.gradient, [1, 0, 0])
  let outside = sdf.sample_gradient([3, 0.5, 0.5], shape_margin=0.125)
  assert_eq(outside.distance, 2.875)
  assert_eq(outside.gradient, [1, 0, 0])
}

///|
test "legacy occupied tile and coarse volume subtract shape margin once" {
  let sdf = @cooking.build_legacy_sdf(
    [0, 0, 0],
    [1, 1, 1],
    {
      margin: 0.1,
      shape_margin: 0.125,
      narrow_band: [-1, 1],
      max_resolution: 8,
      target_voxel_size: None,
    },
    points => Array::make(points.length() / 3, 0.0),
  )
  assert_eq(sdf.sparse.tiles, Bytes::make(12, 0))
  assert_eq(sdf.sparse.background, 1.0e10)
  assert_eq(sdf.coarse.background, 1.0e10)
  assert_eq(sdf.sparse.values.length(), 512 * 4)
  assert_eq(sdf.coarse.values, sdf.sparse.values)
  assert_eq(sdf.sparse.values[0], 0)
  assert_eq(sdf.sparse.values[1], 0)
  assert_eq(sdf.sparse.values[2], 0)
  assert_eq(sdf.sparse.values[3], 0xbe)
}

///|
test "JSON command rejects unconsumed top-level fields" {
  try
    @cooking.decode_geometry_request({
      "operation": "primitive-mass",
      "parameters": {},
      "ambient_python": true,
    })
  catch {
    _ => ()
  } noraise {
    _ => fail("unknown command field must reject")
  }
}
