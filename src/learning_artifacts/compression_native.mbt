///|
#borrow(input, status)
extern "c" fn inflate_ffi(
  input : Bytes,
  window_bits : Int32,
  status : Ref[Int32],
) -> Bytes = "moonrobo_learning_inflate"

///|
pub fn decompress(input : Bytes, raw~ : Bool = false) -> Bytes raise {
  let status = Ref(-1)
  let bytes = inflate_ffi(input, if raw { -15 } else { 31 }, status)
  guard status.val == 0 else {
    fail("invalid, oversized, or unsupported compressed artifact")
  }
  bytes
}

///|
#borrow(input)
extern "c" fn crc32(input : Bytes) -> UInt32 = "moonrobo_learning_crc32"

///|
#borrow(input, status)
extern "c" fn gzip_ffi(input : Bytes, status : Ref[Int32]) -> Bytes = "moonrobo_learning_gzip"

///|
pub fn compress_gzip(input : Bytes) -> Bytes raise {
  let status = Ref(-1)
  let bytes = gzip_ffi(input, status)
  guard status.val == 0 else {
    fail("gzip compression failed or input exceeds 1GB")
  }
  bytes
}
