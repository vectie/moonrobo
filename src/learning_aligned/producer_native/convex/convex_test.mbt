///|
fn request() -> @convex.Request {
  {
    nworld: 2,
    ngeom: 3,
    candidate_capacity: 4,
    vertex_capacity: 5,
    gjk_iterations: 32,
    tolerance: 1.0e-6,
    cutoff: 1.0e32,
  }
}

///|
test "completed convex query accepts distance cutoff and shallow states" {
  @convex.validate_results(request(), 3, [1, 2, 3, 0], [0, 0, 0, 0, 0])
}

///|
test "convex readback rejects incomplete EPA overflow and stale slots" {
  for
    (count, status, rejected) in [
      (1, [10, 0, 0, 0], [0, 0, 0, 0, 0]),
      (1, [11, 0, 0, 0], [0, 0, 0, 0, 0]),
      (1, [13, 0, 0, 0], [0, 0, 0, 0, 0]),
      (1, [1, 0, 0, 0], [1, 0, 0, 0, 0]),
      (1, [1, 1, 0, 0], [0, 0, 0, 0, 0]),
      (5, [1, 1, 1, 1], [0, 0, 0, 0, 0]),
      (1, [1], [0, 0, 0, 0, 0]),
    ] {
    try @convex.validate_results(request(), count, status, rejected) catch {
      _ => ()
    } noraise {
      _ => fail("unsafe readback accepted")
    }
  }
}

///|
test "convex specialization rejects dimensions and nonpositive iteration budget" {
  let base = request()
  for
    r in [
      { ..base, gjk_iterations: 0, },
      { ..base, gjk_iterations: 4097, },
      { ..base, vertex_capacity: -1, },
      { ..base, cutoff: -1.0, },
      { ..base, tolerance: 0.0, },
    ] {
    try @convex.lower(r) catch {
      _ => ()
    } noraise {
      _ => fail("invalid convex specialization accepted")
    }
  }
}
