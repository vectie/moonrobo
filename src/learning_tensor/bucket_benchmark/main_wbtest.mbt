///|
test "paper parameter order and collective counts" {
  let shapes = paper_shapes()
  assert_eq(shapes.map(x => x.length()), [14, 20, 6])
  assert_eq(
    shapes.map(x => x.fold(init=0L, (n, shape) => n + elements(shape))),
    [8822854L, 8993597L, 267265L],
  )
  assert_eq(shapes[0][2], [2048])
  assert_eq(shapes[1][10], [2048, 962])
  assert_eq(shapes[2], [[256, 914], [256], [128, 256], [128], [1, 128], [1]])
  let updates = [10, 1, 20]
  let mut legacy = 0L
  let mut bucket = 0L
  for i, group in shapes {
    let count = group.fold(init=0L, (n, shape) => n + elements(shape))
    legacy += group.fold(init=0L, (n, shape) => {
        n + (elements(shape) + 4194303L) / 4194304L
      }) *
      updates[i].to_int64()
    bucket += (count + 4194303L) / 4194304L * updates[i].to_int64()
  }
  assert_eq(legacy, 280L)
  assert_eq(bucket, 53L)
}

///|
test "NCCL memlock admission rejects Docker default and unbounded limits" {
  assert_eq(
    parse_memlock(
      "Max locked memory         1073741824           1073741824           bytes\n",
    ),
    ({ "soft_bytes": Json(1073741824L), "hard_bytes": Json(1073741824L) } : Json),
  )
  for
    source in [
      "Max locked memory 8388608 8388608 bytes\n", "Max locked memory unlimited unlimited bytes\n",
      "Max locked memory 1073741824 17179869184 bytes\n", "Max locked memory 2147483648 1073741824 bytes\n",
    ] {
    try parse_memlock(source) catch {
      _ => ()
    } noraise {
      _ => fail("unsafe memlock limit was accepted")
    }
  }
}
