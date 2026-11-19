///|
pub(all) struct LegacySdfOptions {
  margin : Double
  shape_margin : Double
  narrow_band : Array[Double]
  max_resolution : Int32
  target_voxel_size : Double?
} derive(FromJson, ToJson)

///|
/// Each tile is an actual aligned voxel-origin xyz int32 triple. Values are
/// Float32, tile-major then z,y,x (x innermost), 512 samples per tile.
pub struct PreparedVolume {
  tiles : Bytes
  values : Bytes
  cell_size : Array[Double]
  lower : Array[Double]
  shape : Array[Int32]
  background : Double
}

///|
pub struct LegacySdf {
  sparse : PreparedVolume
  coarse : PreparedVolume
  lower : Array[Double]
  upper : Array[Double]
  shape_margin : Double
}

///|
pub fn PreparedVolume::metadata(self : PreparedVolume) -> Json {
  {
    "format": "moonrobo.nanovdb-tile-input.v1",
    "tiles_sha256": Json(@artifacts.sha256(self.tiles)),
    "values_sha256": Json(@artifacts.sha256(self.values)),
    "tile_count": Json(self.tiles.length() / 12),
    "shape_xyz": Json(self.shape),
    "cell_size": Json(self.cell_size),
    "lower": Json(self.lower),
    "background": Json(self.background),
    "value_order": "tile,z,y,x",
    "native_volume_created": false,
  }
}

///|
pub fn LegacySdf::metadata(self : LegacySdf) -> Json {
  {
    "format": "moonrobo.legacy-sparse-volume-input.v1",
    "sparse": self.sparse.metadata(),
    "coarse": self.coarse.metadata(),
    "lower": Json(self.lower),
    "upper": Json(self.upper),
    "shape_margin_baked": Json(self.shape_margin),
    "cpu_preparation": true,
    "numeric_equivalence_verified": false,
    "full_newton_cooking_complete": false,
  }
}

///|
fn legacy_values(
  points : Array[Double],
  margin : Double,
  query : (Array[Double]) -> Array[Double] raise,
) -> Bytes raise {
  let result = query(points)
  guard result.length() * 3 == points.length() && result.all(finite) else {
    fail("legacy SDF query cardinality/nonfinite value")
  }
  let result = result.map(x => {
    (Float::from_double(x) - Float::from_double(margin)).to_double()
  })
  // The native query results and subtraction have already rounded to f32.
  floats(result)
}

///|
/// Host port of _compute_sdf_from_shape_impl's occupied 8^3 tile path and
/// independent one-tile coarse volume. Query values are raw signed distance;
/// shape_margin is subtracted exactly once while populating both volumes.
/// No native resource is allocated until open_tile_volume is explicitly used.
pub fn build_legacy_sdf(
  lower : Array[Double],
  upper : Array[Double],
  options : LegacySdfOptions,
  query : (Array[Double]) -> Array[Double] raise,
) -> LegacySdf raise {
  guard lower.length() == 3 &&
    upper.length() == 3 &&
    lower.all(finite) &&
    upper.all(finite) &&
    finite(options.margin) &&
    options.margin > 0 &&
    finite(options.shape_margin) &&
    !Float::from_double(options.shape_margin).is_inf() &&
    options.narrow_band.length() == 2 &&
    options.narrow_band.all(finite) &&
    options.narrow_band[0] < 0 &&
    options.narrow_band[1] > 0 &&
    options.max_resolution >= 8 &&
    options.max_resolution <= 256 &&
    options.max_resolution % 8 == 0 &&
    options.target_voxel_size.map(x => finite(x) && x > 0).unwrap_or(true) else {
    fail("invalid bounded legacy SDF options")
  }
  let offset = options.margin + options.shape_margin
  let low = lower.map(x => x - offset)
  let high = upper.map(x => x + offset)
  let ext = Array::makei(3, k => high[k] - low[k])
  guard low.all(finite) && high.all(finite) && ext.all(x => finite(x) && x > 0) else {
    fail("legacy SDF padding collapses or overflows domain")
  }
  let longest = maxd(ext[0], maxd(ext[1], ext[2]))
  let target = options.target_voxel_size.unwrap_or(
    longest / options.max_resolution.to_double(),
  )
  guard target > 0 && ext.all(x => x / target <= 256) else {
    fail("legacy target voxel size exceeds bounded resolution")
  }
  let dims = ext.map(x => (x / target).to_int() / 8 * 8).map(n => n.max(8))
  let cell = Array::makei(3, k => ext[k] / (dims[k] - 1).to_double())
  guard cell.all(x => {
    finite(x) &&
    x > 0 &&
    !Float::from_double(x).is_inf() &&
    Float::from_double(x) > 0
  }) else {
    fail("legacy voxel size is not finite positive float32")
  }
  let radius = point(cell, 0).scale(4).length()
  let inner = Float::from_double(options.narrow_band[0] - radius)
  let outer = Float::from_double(options.narrow_band[1] + radius)
  guard !inner.is_inf() && !outer.is_inf() else {
    fail("legacy occupancy threshold overflows")
  }
  let tiles = []
  let centers = []
  for x in 0..<(dims[0] / 8) {
    for y in 0..<(dims[1] / 8) {
      for z in 0..<(dims[2] / 8) {
        tiles.push([x * 8, y * 8, z * 8])
        for (k, v) in [(0, x), (1, y), (2, z)] {
          centers.push(
            Float::from_double(low[k] + (v * 8 + 4).to_double() * cell[k]).to_double(),
          )
        }
      }
    }
  }
  let distances = query(centers)
  guard distances.length() == tiles.length() && distances.all(finite) else {
    fail("legacy tile occupancy query failed")
  }
  let active = []
  let values = []
  for i, tile in tiles {
    let distance = Float::from_double(distances[i])
    if !(distance < outer && distance > inner) {
      continue
    }
    for v in tile {
      active.push(v)
    }
    let points = []
    for z in 0..<8 {
      for y in 0..<8 {
        for x in 0..<8 {
          for (k, v) in [(0, x), (1, y), (2, z)] {
            points.push(
              (Float::from_double(low[k]) +
              Float::from_int(tile[k] + v) * Float::from_double(cell[k])).to_double(),
            )
          }
        }
      }
    }
    for byte in legacy_values(points, options.shape_margin, query) {
      values.push(byte)
    }
  }
  let coarse_cell = ext.map(x => x / 7)
  let points = []
  for z in 0..<8 {
    for y in 0..<8 {
      for x in 0..<8 {
        for (k, v) in [(0, x), (1, y), (2, z)] {
          points.push(
            (Float::from_double(low[k]) +
            Float::from_int(v) * Float::from_double(coarse_cell[k])).to_double(),
          )
        }
      }
    }
  }
  let coarse_values = legacy_values(points, options.shape_margin, query)
  {
    sparse: {
      tiles: ints(active),
      values: Bytes::from_array(values),
      cell_size: cell,
      lower: low.copy(),
      shape: dims,
      background: 1.0e10,
    },
    coarse: {
      tiles: ints([0, 0, 0]),
      values: coarse_values,
      cell_size: coarse_cell,
      lower: low.copy(),
      shape: [8, 8, 8],
      background: 1.0e10,
    },
    lower: low,
    upper: high,
    shape_margin: options.shape_margin,
  }
}

///|
#borrow(adapter, library, tiles, values, placement)
extern "c" fn volume_tiles(
  adapter : Bytes,
  library : Bytes,
  tiles : Bytes,
  values : Bytes,
  placement : Bytes,
  background : Float,
) -> NativeField = "moonrobo_volume_tiles"

///|
#borrow(field, points)
extern "c" fn volume_sample(field : NativeField, points : Bytes) -> Bytes = "moonrobo_volume_sample"

///|
/// Actual native NanoVDB tile builder. Empty sparse inputs return None: pinned
/// Warp's native host builder rejects zero points; the coarse volume remains
/// usable. No dummy tile is silently added to an empty sparse field.
pub fn open_tile_volume(
  adapter : String,
  library : String,
  prepared : PreparedVolume,
) -> CookedField? raise {
  guard !adapter.is_empty() &&
    !library.is_empty() &&
    !adapter.contains("\u{0}") &&
    !library.contains("\u{0}") &&
    prepared.tiles.length() % 12 == 0 &&
    prepared.tiles.length() <= 32768 * 12 &&
    prepared.values.length() == prepared.tiles.length() / 12 * 512 * 4 &&
    prepared.cell_size.length() == 3 &&
    prepared.cell_size.all(x => finite(x) && x > 0) &&
    prepared.lower.length() == 3 &&
    prepared.lower.all(finite) &&
    prepared.shape.length() == 3 &&
    prepared.shape.all(n => n >= 8 && n <= 256 && n % 8 == 0) &&
    finite(prepared.background) else {
    fail("invalid sparse volume input")
  }
  let seen : Map[String, Bool] = {}
  for i in 0..<(prepared.tiles.length() / 12) {
    let key = []
    for k in 0..<3 {
      let v = word(prepared.tiles, (i * 3 + k) * 4).reinterpret_as_int()
      guard v >= 0 && v < prepared.shape[k] && v % 8 == 0 else {
        fail("invalid sparse tile origin")
      }
      key.push(v.to_string())
    }
    let key = key.join(":")
    guard !seen.contains(key) else { fail("duplicate sparse tile origin") }
    seen[key] = true
  }
  if prepared.tiles.is_empty() {
    return None
  }
  let transform = prepared.cell_size.copy()
  for x in prepared.lower {
    transform.push(x)
  }
  let native = volume_tiles(
    @utf8.encode(adapter),
    @utf8.encode(library),
    prepared.tiles,
    prepared.values,
    floats(transform),
    Float::from_double(prepared.background),
  )
  let field = CookedField({
    native,
    kind: "nanovdb-float",
    shape: prepared.shape.copy(),
    channels: 1,
    format: "float32",
    closed: Ref(false),
    context: Ref(None),
  })
  errdefer field.close()
  field.check()
  guard field.host_id() != 0UL else { fail("native sparse NanoVDB ID is zero") }
  Some(field)
}

///|
/// Genuine PNanoVDB Float32 linear sampling in world coordinates. Host-only;
/// device IDs are never dereferenced on the CPU.
pub fn CookedField::sample_volume(
  self : CookedField,
  points : Array[Double],
) -> Array[Double] raise {
  self.check()
  guard self.0.kind == "nanovdb-float" &&
    points.length() % 3 == 0 &&
    points.length() <= 12000000 else {
    fail("host NanoVDB and bounded xyz query required")
  }
  if points.is_empty() {
    return []
  }
  let bytes = volume_sample(self.0.native, floats(points))
  self.check()
  guard bytes.length() == points.length() / 3 * 4 else {
    fail("volume sample output span differs")
  }
  let values = Array::makei(bytes.length() / 4, i => {
    Float::reinterpret_from_int(word(bytes, i * 4).to_int()).to_double()
  })
  guard values.all(finite) else { fail("nonfinite native volume query result") }
  values
}

///|
/// Source legacy mesh path always uses winding-number queries. Bake any
/// signed scale with preserve_winding=true before opening this accelerator.
pub fn HostMesh::build_legacy_sdf(
  self : HostMesh,
  options : LegacySdfOptions,
) -> LegacySdf raise {
  self.check()
  guard self.0.prepared.support_winding_number else {
    fail("legacy mesh SDF requires winding-number BVH")
  }
  let current = { ..self.0.prepared, points: self.0.point_bytes.val, }
  let vertices = current.vertices()
  let low = [vertices[0], vertices[1], vertices[2]]
  let high = low.copy()
  for i in 0..<current.vertex_count {
    for k in 0..<3 {
      low[k] = -maxd(-low[k], -vertices[i * 3 + k])
      high[k] = maxd(high[k], vertices[i * 3 + k])
    }
  }
  let mut volume = 0.0
  let idx = current.triangles()
  for i in 0..<current.triangle_count {
    volume += point(vertices, idx[i * 3]).dot(
        point(vertices, idx[i * 3 + 1]).cross(point(vertices, idx[i * 3 + 2])),
      ) /
      6
  }
  build_legacy_sdf(low, high, options, points => {
    self.sample_distances(
      points,
      "winding",
      10000,
      if volume >= 0 {
        0.5
      } else {
        -0.5
      },
    )
  })
}

///|
pub fn primitive_legacy_sdf(
  kind : String,
  scale : Array[Double],
  options : LegacySdfOptions,
) -> LegacySdf raise {
  let ext = primitive_extents(kind, scale)
  build_legacy_sdf(ext.map(x => -x), ext, options, points => {
    Array::makei(points.length() / 3, i => {
      Float::from_double(
        primitive_distance(kind, scale, [
          points[i * 3],
          points[i * 3 + 1],
          points[i * 3 + 2],
        ]),
      ).to_double()
    })
  })
}

///|
/// Genuine native-volume to current texture-storage bridge. Preserves the
/// source's separate coarse query, sparse occupancy/linearity, and late
/// outlier replacement from the coarse volume. Legacy source values already
/// contain shape_margin; no second margin is subtracted.
pub fn LegacySdf::to_texture(
  self : LegacySdf,
  adapter : String,
  library : String,
  options : SdfOptions,
) -> SparseSdf raise {
  guard options.texture_format == "float32" else {
    fail("source volume conversion stores unquantized float32")
  }
  guard open_tile_volume(adapter, library, self.coarse) is Some(coarse) else {
    fail("legacy coarse volume is empty")
  }
  defer coarse.close()
  let sparse = open_tile_volume(adapter, library, self.sparse)
  defer (if sparse is Some(volume) { volume.close() })
  let cell = self.sparse.cell_size
  let band = maxd(options.narrow_band[0].abs(), options.narrow_band[1].abs()) +
    point(cell, 0).scale(4).length()
  fn source(points : Array[Double]) -> Array[Double] raise {
    if sparse is Some(volume) {
      volume.sample_volume(points)
    } else {
      Array::make(points.length() / 3, 1.0e10F.to_double())
    }
  }
  build_sparse_sdf(
    self.lower,
    self.upper,
    options,
    source,
    voxel_size=Some(cell),
    coarse_query=Some(points => coarse.sample_volume(points)),
    populate_query=Some(points => {
      let values = source(points)
      let positions = []
      let indices = []
      for i, value in values {
        if value > band * 2 || value < -band * 2 {
          indices.push(i)
          for k in 0..<3 {
            positions.push(points[i * 3 + k])
          }
        }
      }
      if !positions.is_empty() {
        let replacement = coarse.sample_volume(positions)
        for i, index in indices {
          values[index] = replacement[i]
        }
      }
      values
    }),
  )
}
