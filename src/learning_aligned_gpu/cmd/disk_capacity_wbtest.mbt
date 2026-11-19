///|
test "statvfs byte multiplication is exact and refuses Int64 overflow" {
  assert_eq(checked_disk_product(0UL, 4096UL), 0L)
  assert_eq(checked_disk_product(1024UL, 4096UL), 4194304L)
  assert_eq(
    checked_disk_product(9223372036854775807UL, 1UL),
    9223372036854775807L,
  )
  assert_eq(checked_disk_product(9223372036854775808UL, 1UL), -1L)
  assert_eq(checked_disk_product(9223372036854775807UL, 2UL), -1L)
  assert_eq(checked_disk_product(1UL, 0UL), -1L)
}

///|
async test "output free bytes reads a real temporary directory and fails closed" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="moonrobo-disk-capacity-")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    assert_true(output_free_bytes(root) >= 0L)
    assert_true((try? output_free_bytes("")) is Err(_))
    assert_true((try? output_free_bytes(root + "\u{0}suffix")) is Err(_))
    assert_true((try? output_free_bytes(root + "/absent")) is Err(_))
  }
}
