///|
test "JPEG frames survive arbitrary transport boundaries and leading noise" {
  let decoder = JpegDecoder::new()
  assert_eq(decoder.feed(b"noise\xff").length(), 0)
  assert_eq(decoder.feed(b"\xd8\x01\xff").length(), 0)
  let frames = decoder.feed(b"\xd9\xff\xd8\x02\xff\xd9\xff\xd8")
  assert_eq(frames.length(), 2)
  assert_eq(frames[0], b"\xff\xd8\x01\xff\xd9")
  assert_eq(frames[1], b"\xff\xd8\x02\xff\xd9")
  assert_eq(decoder.feed(b"\x03\xff\xd9")[0], b"\xff\xd8\x03\xff\xd9")
  // Previously returned frame buffers must remain independent of later input.
  assert_eq(frames[0], b"\xff\xd8\x01\xff\xd9")
}
