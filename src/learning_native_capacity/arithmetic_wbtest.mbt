///|
test "checked arithmetic accepts exact Int64 boundary and rejects overflow" {
  assert_eq(checked_add(9223372036854775806L, 1L), 9223372036854775807L)
  assert_eq(checked_mul(9223372036854775807L, 1L), 9223372036854775807L)
  assert_eq(checked_mul(0L, 9223372036854775807L), 0L)
  for (a, b) in [(9223372036854775807L, 1L), (-1L, 1L), (1L, -1L)] {
    try checked_add(a, b) catch {
      _ => ()
    } noraise {
      _ => fail("invalid sum accepted")
    }
  }
  for
    (a, b) in [
      (9223372036854775807L, 2L),
      (3037000500L, 3037000500L),
      (-1L, 0L),
      (0L, -1L),
    ] {
    try checked_mul(a, b) catch {
      _ => ()
    } noraise {
      _ => fail("invalid product accepted")
    }
  }
}
