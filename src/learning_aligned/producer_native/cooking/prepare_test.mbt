///|
// Pending regression sources: typechecked only; no preparation/test execution
// or native resource creation was performed during migration.
fn triangle_request() -> @cooking.MeshRequest {
  {
    vertices: [0, 0, 0, 1, 0, 0, 0, 1, 0],
    indices: [0, 1, 2],
    velocities: [],
    groups: [],
    bvh_constructor: "sah",
    bvh_leaf_size: 4,
    support_winding_number: false,
  }
}

///|
test "explicit local triangle packs exact float32 points and int32 indices" {
  let mesh = @cooking.prepare_mesh(triangle_request())
  assert_eq(mesh.vertex_count, 3)
  assert_eq(mesh.triangle_count, 1)
  assert_eq(
    mesh.points,
    b"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x80\x3f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x80\x3f\x00\x00\x00\x00",
  )
  assert_eq(mesh.indices, b"\x00\x00\x00\x00\x01\x00\x00\x00\x02\x00\x00\x00")
  assert_eq(mesh.velocities, Bytes::make(36, 0))
  assert_true(mesh.groups.is_empty())
  let grouped = @cooking.prepare_mesh({
    ..triangle_request(),
    groups: [-7],
    velocities: [1, 0, 0, 1, 0, 0, 1, 0, 0],
    bvh_constructor: "median",
  })
  assert_eq(grouped.groups, b"\xf9\xff\xff\xff")
  assert_eq(grouped.velocities.length(), 36)
}

///|
test "bad topology and unsupported cooking never infer a fallback" {
  let base = triangle_request()
  for
    request in [
      { ..base, indices: [0, 1, 3], },
      { ..base, indices: [0, 1, 1], },
      { ..base, vertices: [0, 0, 0, 1, 0, 0, 2, 0, 0], },
      { ..base, vertices: [0, 0, 0, 1, 0, 0, 1.000000001, 0, 0], },
      { ..base, indices: [0, 1, 2, 0], },
      { ..base, groups: [0, 1], },
      { ..base, velocities: [0, 0, 0], },
      { ..base, bvh_constructor: "lbvh", },
      { ..base, bvh_constructor: "cubql", },
      { ..base, bvh_leaf_size: 0, },
      { ..base, vertices: [0, 0, 0, 1.0e300, 0, 0, 0, 1, 0], },
    ] {
    try @cooking.prepare_mesh(request) catch {
      _ => ()
    } noraise {
      _ => fail("invalid or unsupported mesh request must reject")
    }
  }
}
