///|
struct JpegDecoder {
  pending : @buffer.Buffer
  mut previous : Byte
  mut inside : Bool
}

///|
fn JpegDecoder::new() -> JpegDecoder {
  { pending: @buffer.Buffer(), previous: 0, inside: false, }
}

///|
// FFmpeg emits concatenated JPEG images. Keep only complete frames and bound
// the incomplete-frame buffer so broken capture cannot grow memory forever.
fn JpegDecoder::feed(self : JpegDecoder, chunk : Bytes) -> Array[Bytes] {
  let frames = []
  for byte in chunk {
    if !self.inside {
      if self.previous == 0xff && byte == 0xd8 {
        self.pending.reset()
        self.pending.write_byte(0xff)
        self.pending.write_byte(0xd8)
        self.inside = true
      }
    } else {
      self.pending.write_byte(byte)
      if self.previous == 0xff && byte == 0xd9 {
        frames.push(self.pending.to_bytes())
        self.pending.reset()
        self.inside = false
      } else if self.pending.length() > 2_000_000 {
        self.pending.reset()
        self.inside = false
      }
    }
    self.previous = byte
  }
  frames
}
