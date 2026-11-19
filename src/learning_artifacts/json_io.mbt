///|
pub async fn load_json(path : String, expected_sha256? : String) -> Json {
  let stored = @fs.read_file(path).binary()
  if expected_sha256 is Some(expected) {
    guard sha256(stored) == expected else {
      fail("JSON archive SHA256 differs")
    }
  }
  @json.parse(
    @utf8.decode(
      if path.has_suffix(".gz") {
        decompress(stored)
      } else {
        stored
      },
    ),
  )
}

///|
/// Hash covers the stored bytes, matching provenance fields in Python reports.
pub async fn save_json(path : String, value : Json) -> String {
  let raw = @utf8.encode(value.stringify())
  let stored = if path.has_suffix(".gz") { compress_gzip(raw) } else { raw }
  @fs.write_file(path, stored, create_mode=CreateOrTruncate)
  sha256(stored)
}

///|
pub async fn load_jsonl(
  path : String,
  expected_sha256? : String,
) -> Array[Json] {
  let stored = @fs.read_file(path).binary()
  if expected_sha256 is Some(expected) {
    guard sha256(stored) == expected else {
      fail("JSONL archive SHA256 differs")
    }
  }
  let raw = if path.has_suffix(".gz") { decompress(stored) } else { stored }
  let rows : Array[Json] = []
  for line in @utf8.decode(raw).split("\n") {
    if !line.trim().is_empty() {
      rows.push(@json.parse(line.to_owned()))
    }
  }
  rows
}

///|
pub async fn save_jsonl(path : String, rows : Array[Json]) -> String {
  let raw = @utf8.encode(
    rows.map(row => row.stringify()).join("\n") +
    (if rows.is_empty() { "" } else { "\n" }),
  )
  let stored = if path.has_suffix(".gz") { compress_gzip(raw) } else { raw }
  @fs.write_file(path, stored, create_mode=CreateOrTruncate)
  sha256(stored)
}
