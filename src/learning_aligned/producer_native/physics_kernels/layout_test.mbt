///|
test "symmetric packed inertia keeps original value addresses" {
  let layout = @physics_kernels.mass_gather_layout(3, [0, 1, 3], [1, 2, 2], [
    0, 0, 1, 0, 2,
  ])
  assert_eq(layout.rowadr, [0, 3, 5, 7])
  assert_eq(layout.col, [0, 1, 2, 0, 1, 0, 2])
  assert_eq(layout.madr, [0, 1, 3, 1, 2, 3, 4])
  assert_eq(layout.source_nnz, 5)
}

///|
test "reject invalid source inertia layout instead of repairing it" {
  for
    (rowadr, rownnz, columns) in [
      ([0, 1], [1, 1], [0, 0]),
      ([0, 2], [1, 1], [0, 0, 1]),
      ([0, 1], [1, 3], [0, 0, 0, 1]),
      ([0, 1], [1, 1], [1, 1]),
      ([0, 1], [1, 1], [0, 1, 1]),
    ] {
    try @physics_kernels.mass_gather_layout(2, rowadr, rownnz, columns) catch {
      _ => ()
    } noraise {
      _ => fail("invalid sparse layout accepted")
    }
  }
}
