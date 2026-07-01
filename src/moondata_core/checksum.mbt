///|
pub fn text_checksum(text : String) -> String {
  let modulo = 1000000007L
  let mut hash = 17L
  for char in text {
    hash = (hash * 257L + char.to_int().to_int64()) % modulo
  }
  "text-sum-v1:\{text.length()}:\{hash}"
}

///|
pub fn bytes_checksum(bytes : Bytes) -> String {
  let modulo = 1000000007L
  let mut hash = 17L
  for index in 0..<bytes.length() {
    hash = (hash * 257L + bytes[index].to_int().to_int64()) % modulo
  }
  "bytes-sum-v1:\{bytes.length()}:\{hash}"
}
