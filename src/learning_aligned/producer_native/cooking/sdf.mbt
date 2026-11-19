///|
pub(all) struct SdfOptions {
  margin : Double
  narrow_band : Array[Double]
  max_resolution : Int32
  target_voxel_size : Double?
  texture_format : String
  paired_samples : Bool
  sign_method : String
  linearization_error : Double?
} derive(FromJson, ToJson)

///|
/// Actual Newton sparse texture arrays. Shape is z,y,x for textures and x,y,z
/// for slot indirection. These are real cooked bytes, not a live CUDA texture.
pub struct SparseSdf {
  coarse : Bytes
  subgrid : Bytes
  slots : Bytes
  coarse_shape : Array[Int32]
  slot_shape : Array[Int32]
  subgrid_size : Int32
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
}

///|
fn packed_texture(
  values : Array[Double],
  shape : Array[Int32],
  format : String,
  paired : Bool,
  minimum : Double,
  range : Double,
) -> Bytes raise {
  guard shape.length() == 3 &&
    shape.all(n => n > 0 && n <= 256) &&
    shape[0] * shape[1] * shape[2] == values.length() &&
    values.all(finite) &&
    finite(minimum) &&
    finite(range) &&
    range > 0 else {
    fail("texture shape/value/range mismatch")
  }
  let out = []
  let maximum = if format == "uint16" { 65535 } else { 255 }
  for i, value in values {
    let next = if i % shape[2] + 1 < shape[2] { i + 1 } else { i }
    for component in 0..<(if paired { 2 } else { 1 }) {
      let x = if component == 0 { value } else { values[next] }
      if format == "float32" {
        let f = Float::from_double(x)
        guard !f.is_inf() && !f.is_nan() else {
          fail("SDF float32 sample overflows")
        }
        let bits = f.reinterpret_as_uint()
        for k in 0..<4 {
          out.push(((bits >> (8 * k)) & 255U).to_byte())
        }
      } else {
        let xf = Float::from_double(x)
        let mf = Float::from_double(minimum)
        let inverse = Float::from_double(1.0 / range)
        guard !xf.is_inf() && !mf.is_inf() && !inverse.is_inf() && inverse > 0 else {
          fail("SDF quantization operands overflow or underflow float32")
        }
        let value = (xf - mf) * inverse
        guard !value.is_nan() else {
          fail("SDF float32 quantization is not finite")
        }
        let normalized = if value < 0 {
          0.0F
        } else if value > 1 {
          1.0F
        } else {
          value
        }
        let q = (normalized * Float::from_int(maximum)).to_int()
        out.push((q & 255).to_byte())
        if format == "uint16" {
          out.push(((q >> 8) & 255).to_byte())
        }
      }
    }
  }
  Bytes::from_array(out)
}

///|
fn trilinear(
  coarse : Array[Double],
  nx : Int32,
  ny : Int32,
  bx : Int32,
  by : Int32,
  bz : Int32,
  x : Double,
  y : Double,
  z : Double,
) -> Double {
  fn get(dx : Int32, dy : Int32, dz : Int32) -> Double {
    coarse[((bz + dz) * ny + by + dy) * nx + bx + dx]
  }
  let a = get(0, 0, 0) * (1 - x) + get(1, 0, 0) * x
  let b = get(0, 1, 0) * (1 - x) + get(1, 1, 0) * x
  let c = get(0, 0, 1) * (1 - x) + get(1, 0, 1) * x
  let d = get(0, 1, 1) * (1 - x) + get(1, 1, 1) * x
  (a * (1 - y) + b * y) * (1 - z) + (c * (1 - y) + d * y) * z
}

///|
/// CPU host orchestration port of _build_sparse_sdf: coarse queries,
/// center occupancy, full 9^3 linearity test, exclusive addresses, slot bits,
/// 8/16/f32 subgrid quantization and paired-X packing. The supplied source
/// query is explicit and must return signed metres in the same local frame.
pub fn build_sparse_sdf(
  lower : Array[Double],
  upper : Array[Double],
  options : SdfOptions,
  query : (Array[Double]) -> Array[Double] raise,
  voxel_size~ : Array[Double]? = None,
  coarse_query~ : ((Array[Double]) -> Array[Double] raise)? = None,
  populate_query~ : ((Array[Double]) -> Array[Double] raise)? = None,
) -> SparseSdf raise {
  guard lower.length() == 3 &&
    upper.length() == 3 &&
    lower.all(finite) &&
    upper.all(finite) &&
    options.margin >= 0 &&
    finite(options.margin) &&
    options.narrow_band.length() == 2 &&
    options.narrow_band.all(finite) &&
    options.max_resolution >= 1 &&
    options.max_resolution <= 256 &&
    ["float32", "uint16", "uint8"].contains(options.texture_format) &&
    options.linearization_error.map(x => finite(x) && x >= 0).unwrap_or(true) else {
    fail("unsupported bounded sparse SDF options")
  }
  let ext = Array::makei(3, k => upper[k] - lower[k])
  guard ext.all(x => finite(x) && x > 0) else {
    fail("nondegenerate padded SDF extents required")
  }
  let longest = maxd(ext[0], maxd(ext[1], ext[2]))
  let mut resolution = options.max_resolution
  if options.target_voxel_size is Some(size) {
    guard finite(size) && size > 0 && longest / size <= 256 else {
      fail("target SDF voxel resolution exceeds 256")
    }
    let required = @math.ceil(longest / size).to_int()
    resolution = ((required + 7) / 8 * 8).max(8)
  }
  if voxel_size is Some(size) {
    guard size.length() == 3 &&
      size.all(x => finite(x) && x > 0) &&
      [0, 1, 2].all(k => ext[k] / size[k] <= 256) else {
      fail("explicit source voxel size exceeds bounded resolution")
    }
  }
  let dims = Array::makei(3, k => {
    match voxel_size {
      Some(size) => @math.floor(ext[k] / size[k] + 0.5).to_int() + 1
      None =>
        @math.ceil(ext[k] / (longest / resolution.to_double())).to_int() + 1
    }
  })
  guard dims.all(n => n >= 2 && n <= 257) else {
    fail("SDF aspect ratio produces a collapsed grid axis")
  }
  let cell = voxel_size
    .map(x => x.copy())
    .unwrap_or_else(() => {
      Array::makei(3, k => ext[k] / (dims[k] - 1).to_double())
    })
  guard cell.all(x => finite(x) && x > 0) else {
    fail("SDF cell size overflows or underflows")
  }
  let w = (dims[0] - 1 + 7) / 8
  let h = (dims[1] - 1 + 7) / 8
  let d = (dims[2] - 1 + 7) / 8
  let count = w * h * d
  guard count <= 65536 else { fail("sparse SDF block count exceeds 65536") }
  let coarse_points = []
  for z in 0..<=d {
    for y in 0..<=h {
      for x in 0..<=w {
        for (axis, value) in [(0, x), (1, y), (2, z)] {
          coarse_points.push(
            Float::from_double(lower[axis] + value.to_double() * 8 * cell[axis]).to_double(),
          )
        }
      }
    }
  }
  let coarse = coarse_query.unwrap_or(query)(coarse_points)
  guard coarse.length() == (w + 1) * (h + 1) * (d + 1) && coarse.all(finite) else {
    fail("coarse SDF source query failed")
  }
  let centers = []
  for z in 0..<d {
    for y in 0..<h {
      for x in 0..<w {
        for (axis, value) in [(0, x), (1, y), (2, z)] {
          centers.push(
            Float::from_double(
              lower[axis] + (value.to_double() * 8 + 4) * cell[axis],
            ).to_double(),
          )
        }
      }
    }
  }
  let center_values = query(centers)
  guard center_values.length() == count && center_values.all(finite) else {
    fail("SDF center source query failed")
  }
  let radius = 4.0 *
    (cell[0] * cell[0] + cell[1] * cell[1] + cell[2] * cell[2]).sqrt()
  let band = maxd(options.narrow_band[0].abs(), options.narrow_band[1].abs()) +
    radius
  guard finite(band) && band > 0 && finite(2.0 * band) else {
    fail("SDF narrow-band range overflows")
  }
  let required = center_values.map(x => x < band && x > -band)
  let linear = Array::make(count, false)
  let threshold = options.linearization_error.unwrap_or(
    1.0e-6 * (ext[0] * ext[0] + ext[1] * ext[1] + ext[2] * ext[2]).sqrt(),
  )
  let samples : Map[Int32, Array[Double]] = {}
  let mut active = 0
  let mut nlinear = 0
  for block in 0..<count {
    if !required[block] {
      continue
    }
    let bx = block % w
    let by = block / w % h
    let bz = block / (w * h)
    let points = []
    for z in 0..<=8 {
      for y in 0..<=8 {
        for x in 0..<=8 {
          for
            (axis, value) in [(0, bx * 8 + x), (1, by * 8 + y), (2, bz * 8 + z)] {
            points.push(
              Float::from_double(lower[axis] + value.to_double() * cell[axis]).to_double(),
            )
          }
        }
      }
    }
    let values = query(points)
    guard values.length() == 729 && values.all(finite) else {
      fail("fine SDF source query failed")
    }
    let mut error = 0.0
    if threshold > 0 {
      for z in 0..<=8 {
        for y in 0..<=8 {
          for x in 0..<=8 {
            error = maxd(
              error,
              (values[(z * 9 + y) * 9 + x] -
              trilinear(
                coarse,
                w + 1,
                h + 1,
                bx,
                by,
                bz,
                x.to_double() / 8,
                y.to_double() / 8,
                z.to_double() / 8,
              )).abs(),
            )
          }
        }
      }
    }
    if threshold > 0 && error < threshold {
      required[block] = false
      linear[block] = true
      nlinear += 1
    } else {
      let final_values = populate_query.map(f => f(points)).unwrap_or(values)
      guard final_values.length() == 729 && final_values.all(finite) else {
        fail("fine SDF population query failed")
      }
      samples[block] = final_values
      active += 1
    }
  }
  let mut blocks = 1
  while blocks * blocks * blocks < active {
    blocks += 1
  }
  let size = if active == 0 { 1 } else { blocks * 9 }
  guard size <= 256 else {
    fail("packed SDF texture exceeds supported 256^3 capacity")
  }
  // GPU wp.zeros(uint*) leaves padding texels at integer zero. Initialize
  // unused source values to the quantization minimum, not physical distance0.
  let texture = Array::make(
    size * size * size,
    if active > 0 && options.texture_format != "float32" {
      -band
    } else {
      0.0
    },
  )
  let slots = Array::make(count, 0xffffffffU)
  let mut address = 0
  for block in 0..<count {
    let bx = block % w
    let by = block / w % h
    let bz = block / (w * h)
    let slot = (bx * h + by) * d + bz
    if linear[block] {
      slots[slot] = 0xfffffffeU
      continue
    }
    if !required[block] {
      continue
    }
    let ax = address % blocks
    let ay = address / blocks % blocks
    let az = address / (blocks * blocks)
    slots[slot] = ax.to_uint() | (ay.to_uint() << 10) | (az.to_uint() << 20)
    let values = samples[block]
    for z in 0..<=8 {
      for y in 0..<=8 {
        for x in 0..<=8 {
          texture[((az * 9 + z) * size + ay * 9 + y) * size + ax * 9 + x] = values[(
              z * 9 + y
            ) *
            9 +
            x]
        }
      }
    }
    address += 1
  }
  let min_value = if active == 0 || options.texture_format == "float32" {
    0.0
  } else {
    -band
  }
  let value_range = if active == 0 ||
    options.texture_format == "float32" ||
    2.0 * band < 1.0e-10 {
    1.0
  } else {
    2.0 * band
  }
  let format = if active == 0 { "float32" } else { options.texture_format }
  let slot_bytes = []
  for value in slots {
    for k in 0..<4 {
      slot_bytes.push(((value >> (k * 8)) & 255U).to_byte())
    }
  }
  {
    coarse: packed_texture(
      coarse,
      [d + 1, h + 1, w + 1],
      "float32",
      options.paired_samples,
      0,
      1,
    ),
    subgrid: packed_texture(
      texture,
      [size, size, size],
      format,
      options.paired_samples,
      min_value,
      value_range,
    ),
    slots: Bytes::from_array(slot_bytes),
    coarse_shape: [d + 1, h + 1, w + 1],
    slot_shape: [w, h, d],
    subgrid_size: 8,
    texture_size: size,
    texture_format: format,
    paired_samples: options.paired_samples,
    lower: lower.copy(),
    upper: Array::makei(3, k => {
      lower[k] + [w, h, d][k].to_double() * 8 * cell[k]
    }),
    cell_size: cell,
    value_min: min_value,
    value_range,
    required_count: active,
    linear_count: nlinear,
    sign_method: options.sign_method,
  }
}

///|
pub fn HostMesh::build_sparse_sdf(
  self : HostMesh,
  options : SdfOptions,
) -> SparseSdf raise {
  self.check()
  let current = { ..self.0.prepared, points: self.0.point_bytes.val, }
  let v = current.vertices()
  let lower = [v[0], v[1], v[2]]
  let upper = lower.copy()
  for i in 0..<self.0.prepared.vertex_count {
    for k in 0..<3 {
      lower[k] = -maxd(-lower[k], -v[i * 3 + k])
      upper[k] = maxd(upper[k], v[i * 3 + k])
    }
  }
  for k in 0..<3 {
    lower[k] -= options.margin
    upper[k] += options.margin
  }
  let sign_method = if options.sign_method == "auto" {
    if mesh_topology(current, 0).watertight {
      "parity"
    } else {
      "winding"
    }
  } else {
    options.sign_method
  }
  let mut volume = 0.0
  let idx = self.0.prepared.triangles()
  for t in 0..<self.0.prepared.triangle_count {
    volume += point(v, idx[t * 3]).dot(
        point(v, idx[t * 3 + 1]).cross(point(v, idx[t * 3 + 2])),
      ) /
      6
  }
  let threshold = if volume >= 0 { 0.5 } else { -0.5 }
  build_sparse_sdf(lower, upper, { ..options, sign_method, }, points => {
    self.sample_distances(points, sign_method, 10000, threshold)
  })
}

///|
pub fn SparseSdf::metadata(self : SparseSdf) -> Json {
  {
    "format": "moonrobo.newton-sparse-texture-bytes.v1",
    "coarse_shape_zyx": Json(self.coarse_shape),
    "slot_shape_xyz": Json(self.slot_shape),
    "texture_size": Json(self.texture_size),
    "subgrid_size": 8,
    "paired_samples": Json(self.paired_samples),
    "texture_format": Json(self.texture_format),
    "lower": Json(self.lower),
    "upper": Json(self.upper),
    "cell_size": Json(self.cell_size),
    "value_min": Json(self.value_min),
    "value_range": Json(self.value_range),
    "required_count": Json(self.required_count),
    "linear_count": Json(self.linear_count),
    "sign_method": Json(self.sign_method),
    "coarse_sha256": Json(@artifacts.sha256(self.coarse)),
    "subgrid_sha256": Json(@artifacts.sha256(self.subgrid)),
    "slots_sha256": Json(@artifacts.sha256(self.slots)),
    "cpu_preparation": true,
    "cuda_textures_created": false,
    "numeric_equivalence_verified": false,
    "full_newton_cooking_complete": false,
  }
}
