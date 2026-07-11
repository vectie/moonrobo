///|
fn sha256_checksum(bytes : Bytes) -> String {
  let digest = @crypto.sha256(bytes)
  let mut hex = ""
  for byte in digest {
    hex = hex + byte.to_hex()
  }
  "sha256:" + hex
}

///|
pub fn text_checksum(text : String) -> String {
  sha256_checksum(@utf8.encode(text))
}

///|
pub fn bytes_checksum(bytes : Bytes) -> String {
  sha256_checksum(bytes)
}
