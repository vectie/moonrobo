///|
/// Independent streaming CSV/catalog oracle. It never calls parse_motion_csv,
/// MotionLibrary, or the candidate catalog-verification implementation.
async fn catalog_mathematical_oracle(
  folder : String,
  sha : String,
) -> Map[String, @artifacts.NumericArray] {
  let raw = verify_file(folder, { path: "motion-manifest.json", sha256: sha, })
  let manifest = @json.parse(@utf8.decode(raw))
  let revision : String = @json.from_json(field(manifest, "source_revision"))
  let clips : Array[Json] = @json.from_json(field(manifest, "clips"))
  let split = field(manifest, "splits")
  guard revision == "ce1572906efe6157840e8474d5a0d7aa87481e74" &&
    clips.length() == 40 &&
    field(split, "train") == field(split, "evaluation") else {
    fail("independent source catalog identity mismatch")
  }
  let fps : Double = @json.from_json(field(manifest, "source_fps"))
  let mut total = 0
  let mut target = 0
  for clip in clips {
    let file : String = @json.from_json(field(clip, "path"))
    let hash : String = @json.from_json(field(clip, "sha256"))
    let declared : Int32 = @json.from_json(field(clip, "source_frames"))
    let text = @utf8.decode(verify_file(folder, { path: file, sha256: hash, }))
    let mut count = 0
    for line in text.split("\n") {
      let data = match line.split_once("#") {
        Some((data, _)) => data.trim()
        None => line.trim()
      }
      if data.is_empty() {
        continue
      }
      let fields = data.split(",").collect()
      guard fields.length() == 36 else {
        fail("independent CSV column count mismatch")
      }
      let values = fields.map(s => @string.parse_double(s.trim()))
      guard values.all(finite) else {
        fail("independent source CSV nonfinite value")
      }
      let norm = values[3] * values[3] +
        values[4] * values[4] +
        values[5] * values[5] +
        values[6] * values[6]
      guard norm.sqrt() > 0.99 else {
        fail("independent source quaternion norm mismatch")
      }
      count += 1
    }
    guard count == declared else {
      fail("independent source frame count mismatch")
    }
    total += count
    target += @math.floor((declared - 1).to_double() / fps / 0.02).to_int() + 1
  }
  guard total == 264705 else {
    fail("independent source corpus total mismatch")
  }
  {
    "clip_count": scalar(40.0),
    "source_frame_count": scalar(total.to_double()),
    "resampled_frame_count": scalar(target.to_double()),
    "all_sha_valid": scalar(1.0),
    "split_equal": scalar(1.0),
    "source_revision_utf8": array(
      [revision.length()],
      @utf8.encode(revision).to_array().map(b => b.to_int().to_double()),
      dtype="|u1",
    ),
  }
}
