///|
test "full BONES eager catalogs are rejected before reading source files" {
  require_native_eager_catalog_size(1)
  require_native_eager_catalog_size(40)
  assert_true(
    (Ok(require_native_eager_catalog_size(129514)) catch { e => Err(e) })
    is Err(_),
  )
  assert_true(
    (Ok(require_native_eager_catalog_size(142220)) catch { e => Err(e) })
    is Err(_),
  )
}
