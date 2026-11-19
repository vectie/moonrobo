///|
#borrow(path)
extern "c" fn output_free_bytes_native(path : Bytes) -> Int64 = "moonrobo_output_free_bytes"

///|
extern "c" fn checked_disk_product(
  available : UInt64,
  fragment_size : UInt64,
) -> Int64 = "moonrobo_checked_disk_product"

///|
/// Read available bytes for a caller-selected existing path. This is a
/// point-in-time filesystem observation, not reserved capacity.
fn output_free_bytes(path : String) -> Int64 raise {
  guard !path.is_empty() && !path.contains("\u{0}") else {
    fail("output disk path must be nonempty and contain no NUL")
  }
  let bytes = @utf8.encode(path)
  guard bytes.length() <= 4096 else {
    fail("output disk path exceeds 4096 UTF-8 bytes")
  }
  let available = output_free_bytes_native(bytes)
  guard available >= 0L else {
    fail("output disk free-space query failed or exceeded Int64")
  }
  available
}
