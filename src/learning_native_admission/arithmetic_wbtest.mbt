///|
test "checked memory arithmetic rejects negative inputs and Int64 overflow" {
  for
    operation in [
      () => add(-1L, 0L),
      () => add(9223372036854775807L, 1L),
      () => mul(9223372036854775807L, 2L),
    ] {
    let rejected = try {
      ignore(operation())
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
  assert_eq(mul(0L, 9223372036854775807L), 0L)
  assert_eq(ceil_div(9223372036854775807L, 2L), 4611686018427387904L)
}
