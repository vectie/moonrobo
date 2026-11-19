///|
struct SdfRecord {
  format : String
  key : String
  coarse_shape : Array[Int32]
  slot_shape : Array[Int32]
  texture_size : Int32
  texture_format : String
  paired_samples : Bool
  lower : Array[Double]
  upper : Array[Double]
  cell_size : Array[Double]
  value_min : Double
  value_range : Double
  required_count : Int32
  linear_count : Int32
  sign_method : String
  coarse_sha256 : String
  subgrid_sha256 : String
  slots_sha256 : String
} derive(FromJson, ToJson)

///|
fn sha_key(key : String) -> Unit raise {
  guard key.length() == 64 &&
    key.to_array().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) else {
    fail("cache key must be a lowercase SHA256")
  }
}

///|
/// Content key includes actual source bytes, resolved/explicit options and
/// adapter/root-Warp identities; shape_margin is deliberately sample-time.
/// Replacing an implementation or runtime invalidates previous stored bytes.
pub async fn mesh_sdf_cache_key(
  mesh : PreparedMesh,
  options : SdfOptions,
  adapter : String,
  library : String,
) -> String {
  let ad = explicit_file(adapter)
  let lib = explicit_file(library)
  let recipe : Json = {
    "format": "moonrobo.mesh-sdf-cache-key.v1",
    "geometry": mesh.metadata(),
    "options": options.to_json(),
    "adapter": Json(ad),
    "warp_library": Json(lib),
    "adapter_sha256": Json(@artifacts.sha256(@fs.read_file(ad).binary())),
    "warp_library_sha256": Json(@artifacts.sha256(@fs.read_file(lib).binary())),
    "source_pin": "71eeba16a717d4dcf0b9dd7056a7b6f863054dc3",
    "cpu_builder_revision": 1,
  }
  @artifacts.sha256(@utf8.encode(recipe.stringify()))
}

///|
pub fn primitive_sdf_cache_key(
  kind : String,
  scale : Array[Double],
  options : SdfOptions,
) -> String raise {
  ignore(primitive_extents(kind, scale))
  let recipe : Json = {
    "format": "moonrobo.primitive-sdf-cache-key.v1",
    "kind": Json(kind),
    "scale": Json(scale),
    "options": options.to_json(),
    "source_pin": "71eeba16a717d4dcf0b9dd7056a7b6f863054dc3",
    "cpu_builder_revision": 1,
  }
  @artifacts.sha256(@utf8.encode(recipe.stringify()))
}

///|
/// Persist actual typed cooking arrays in a fresh content-addressed directory.
/// entry.json is published last; incomplete writes cannot be mistaken for a
/// cache hit. This is a MoonBit binary format, not upstream NumPy NPZ.
pub async fn store_sdf_cache(
  directory : String,
  key : String,
  sdf : SparseSdf,
) -> Json {
  sha_key(key)
  sdf.validate_storage()
  guard !directory.is_empty() && !directory.contains("\u{0}") else {
    fail("explicit cache directory required")
  }
  @fs.mkdir(directory, recursive=true)
  let root = @fs.realpath(directory)
  let path = root + "/" + key
  guard !@fs.exists(path) else {
    fail("SDF cache entry already exists; do not overwrite live content")
  }
  @fs.mkdir(path)
  let record : SdfRecord = {
    format: "moonrobo.sdf-disk-cache.v1",
    key,
    coarse_shape: sdf.coarse_shape.copy(),
    slot_shape: sdf.slot_shape.copy(),
    texture_size: sdf.texture_size,
    texture_format: sdf.texture_format,
    paired_samples: sdf.paired_samples,
    lower: sdf.lower.copy(),
    upper: sdf.upper.copy(),
    cell_size: sdf.cell_size.copy(),
    value_min: sdf.value_min,
    value_range: sdf.value_range,
    required_count: sdf.required_count,
    linear_count: sdf.linear_count,
    sign_method: sdf.sign_method,
    coarse_sha256: @artifacts.sha256(sdf.coarse),
    subgrid_sha256: @artifacts.sha256(sdf.subgrid),
    slots_sha256: @artifacts.sha256(sdf.slots),
  }
  for
    (name, bytes) in [
      ("coarse.bin", sdf.coarse),
      ("subgrid.bin", sdf.subgrid),
      ("slots.bin", sdf.slots),
    ] {
    @fs.write_file(path + "/" + name, bytes, create_mode=CreateNew)
  }
  @fs.write_file(
    path + "/entry.json",
    record.to_json().stringify(indent=2),
    create_mode=CreateNew,
  )
  {
    "path": Json(path),
    "key": Json(key),
    "entry": record.to_json(),
    "native_resources_cached": false,
  }
}

///|
/// Reload real immutable cooking bytes, validate SHA/layout/sentinel addresses
/// before returning them. Native pointers/resource IDs are never persisted or
/// reused. Missing/unpublished entries return None; corrupt entries fail.
pub async fn load_sdf_cache(directory : String, key : String) -> SparseSdf? {
  sha_key(key)
  guard !directory.is_empty() && !directory.contains("\u{0}") else {
    fail("explicit cache directory required")
  }
  let path = directory + "/" + key
  if !@fs.exists(path + "/entry.json") {
    return None
  }
  let json = @json.parse(@fs.read_file(path + "/entry.json").text())
  strict_parameters(json, [
    "format", "key", "coarse_shape", "slot_shape", "texture_size", "texture_format",
    "paired_samples", "lower", "upper", "cell_size", "value_min", "value_range",
    "required_count", "linear_count", "sign_method", "coarse_sha256", "subgrid_sha256",
    "slots_sha256",
  ])
  let r : SdfRecord = @json.from_json(json)
  guard r.format == "moonrobo.sdf-disk-cache.v1" && r.key == key else {
    fail("SDF cache format/key mismatch")
  }
  let coarse = @fs.read_file(path + "/coarse.bin").binary()
  let subgrid = @fs.read_file(path + "/subgrid.bin").binary()
  let slots = @fs.read_file(path + "/slots.bin").binary()
  guard @artifacts.sha256(coarse) == r.coarse_sha256 &&
    @artifacts.sha256(subgrid) == r.subgrid_sha256 &&
    @artifacts.sha256(slots) == r.slots_sha256 else {
    fail("cached SDF byte SHA mismatch")
  }
  let sdf : SparseSdf = {
    coarse,
    subgrid,
    slots,
    coarse_shape: r.coarse_shape,
    slot_shape: r.slot_shape,
    texture_size: r.texture_size,
    subgrid_size: 8,
    texture_format: r.texture_format,
    paired_samples: r.paired_samples,
    lower: r.lower,
    upper: r.upper,
    cell_size: r.cell_size,
    value_min: r.value_min,
    value_range: r.value_range,
    required_count: r.required_count,
    linear_count: r.linear_count,
    sign_method: r.sign_method,
  }
  sdf.validate_storage()
  Some(sdf)
}

///|
/// Full storage/slot validation at cache/upload boundaries. Software per-point
/// queries perform cheaper shape/address checks instead of scanning all bytes.
pub fn SparseSdf::validate_storage(sdf : SparseSdf) -> Unit raise {
  sdf.validate()
  let slots = sdf.slots
  let coarse = sdf.coarse
  let subgrid = sdf.subgrid
  let mut active = 0
  let mut linear = 0
  let seen : Map[UInt32, Bool] = {}
  for i in 0..<(slots.length() / 4) {
    let slot = word(slots, i * 4)
    if slot == 0xfffffffeU {
      linear += 1
    } else if slot != 0xffffffffU {
      active += 1
      guard !seen.contains(slot) else {
        fail("cached SDF active slots are not unique")
      }
      seen[slot] = true
      guard [0, 1, 2].all(k => {
          ((slot >> (10 * k)) & 1023U).to_int() * 9 + 8 < sdf.texture_size
        }) &&
        slot >> 30 == 0U else {
        fail("cached SDF slot points outside actual texture")
      }
    }
  }
  guard active == sdf.required_count &&
    linear == sdf.linear_count &&
    (if active == 0 {
      sdf.texture_size == 1 && sdf.texture_format == "float32"
    } else {
      sdf.texture_size % 9 == 0
    }) else {
    fail("cached SDF active/linear counts or packing differ")
  }
  for i in 0..<(coarse.length() / 4) {
    let value = Float::reinterpret_from_int(word(coarse, i * 4).to_int())
    guard !value.is_inf() && !value.is_nan() else {
      fail("nonfinite cached coarse SDF")
    }
  }
  if sdf.texture_format == "float32" {
    for i in 0..<(subgrid.length() / 4) {
      let value = Float::reinterpret_from_int(word(subgrid, i * 4).to_int())
      guard !value.is_inf() && !value.is_nan() else {
        fail("nonfinite cached fine SDF")
      }
    }
  }
}
