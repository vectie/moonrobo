///|
pub(all) struct SdfSample {
  distance : Double
  gradient : Array[Double]
} derive(ToJson)

///|
fn clampd(x : Double, lower : Double, upper : Double) -> Double {
  -maxd(-upper, -maxd(lower, x))
}

///|
fn SparseSdf::validate(self : SparseSdf) -> Unit raise {
  guard self.coarse_shape.length() == 3 &&
    self.slot_shape.length() == 3 &&
    self.coarse_shape.all(n => n >= 2 && n <= 33) &&
    self.slot_shape.all(n => n >= 1 && n <= 32) &&
    self.coarse_shape[0] == self.slot_shape[2] + 1 &&
    self.coarse_shape[1] == self.slot_shape[1] + 1 &&
    self.coarse_shape[2] == self.slot_shape[0] + 1 &&
    self.texture_size >= 1 &&
    self.texture_size <= 256 &&
    self.subgrid_size == 8 &&
    self.lower.length() == 3 &&
    self.upper.length() == 3 &&
    self.cell_size.length() == 3 &&
    self.lower.all(finite) &&
    self.upper.all(finite) &&
    self.cell_size.all(x => finite(x) && x > 0) &&
    finite(self.value_min) &&
    finite(self.value_range) &&
    self.value_range > 0 &&
    ["float32", "uint16", "uint8"].contains(self.texture_format) else {
    fail("invalid sparse SDF layout")
  }
  for k in 0..<3 {
    guard self.upper[k] > self.lower[k] &&
      (self.upper[k] -
      self.lower[k] -
      self.slot_shape[k].to_double() * 8 * self.cell_size[k]).abs() <=
      1.0e-10 * maxd(1, self.upper[k].abs()) else {
      fail("SDF domain/grid mismatch")
    }
  }
  let channels = if self.paired_samples { 2 } else { 1 }
  let width = if self.texture_format == "float32" {
    4
  } else if self.texture_format == "uint16" {
    2
  } else {
    1
  }
  guard self.coarse.length() ==
    self.coarse_shape[0] *
    self.coarse_shape[1] *
    self.coarse_shape[2] *
    channels *
    4 &&
    self.subgrid.length() ==
    self.texture_size * self.texture_size * self.texture_size * channels * width &&
    self.slots.length() ==
    self.slot_shape[0] * self.slot_shape[1] * self.slot_shape[2] * 4 else {
    fail("SDF byte count differs from typed shape")
  }
}

///|
fn read_texel(
  bytes : Bytes,
  shape : Array[Int32],
  coordinates : Array[Int32],
  paired : Bool,
  format : String,
) -> Float raise {
  guard coordinates.length() == 3 &&
    [0, 1, 2].all(k => coordinates[k] >= 0 && coordinates[k] < shape[2 - k]) else {
    fail("SDF texel address is outside storage")
  }
  let i = (
      (coordinates[2] * shape[1] + coordinates[1]) * shape[2] + coordinates[0]
    ) *
    (if paired { 2 } else { 1 })
  let value = if format == "float32" {
    Float::reinterpret_from_int(word(bytes, i * 4).to_int())
  } else if format == "uint16" {
    Float::from_uint(bytes[i * 2].to_uint() | (bytes[i * 2 + 1].to_uint() << 8)) /
    65535.0F
  } else {
    Float::from_uint(bytes[i].to_uint()) / 255.0F
  }
  guard !value.is_inf() && !value.is_nan() else { fail("nonfinite SDF texel") }
  value
}

///|
// Returns raw corners, interpolation weights, fine/coarse selection, and
// outside displacement. Integer-X pairs are layout-compatible; channel zero
// suffices for the eight explicit point reads in the software path.
fn SparseSdf::cell(
  self : SparseSdf,
  position : Array[Double],
) -> (Array[Float], Array[Float], Bool, Array[Float]) raise {
  self.validate()
  guard position.length() == 3 && position.all(finite) else {
    fail("finite xyz SDF position required")
  }
  let diff = Array::make(3, 0.0F)
  let fine = Array::make(3, 0)
  let base = Array::make(3, 0)
  let weights = Array::make(3, 0.0F)
  for k in 0..<3 {
    let p = Float::from_double(position[k])
    let low = Float::from_double(self.lower[k])
    let high = Float::from_double(self.upper[k])
    let inverse = Float::from_double(1.0 / self.cell_size[k])
    guard !p.is_inf() &&
      !low.is_inf() &&
      !high.is_inf() &&
      !inverse.is_inf() &&
      inverse > 0 else {
      fail("SDF query/domain is not representable in float32")
    }
    let clamped = Float::from_double(
      clampd(p.to_double(), low.to_double(), high.to_double()),
    )
    diff[k] = p - clamped
    let f = ((clamped - low) * inverse).to_double()
    let f = clampd(f, 0, self.slot_shape[k].to_double() * 8)
    fine[k] = @math.floor(f).to_int().max(0).min(self.slot_shape[k] * 8 - 1)
    base[k] = fine[k] / 8
    weights[k] = Float::from_double(f) - Float::from_int(fine[k])
  }
  let slot = word(
    self.slots,
    ((base[0] * self.slot_shape[1] + base[1]) * self.slot_shape[2] + base[2]) *
    4,
  )
  let is_fine = slot < 0xfffffffeU
  let origin = base.copy()
  let shape = if is_fine {
    [self.texture_size, self.texture_size, self.texture_size]
  } else {
    self.coarse_shape
  }
  if is_fine {
    for k in 0..<3 {
      origin[k] = ((slot >> (10 * k)) & 1023U).to_int() * 9 +
        fine[k] -
        base[k] * 8
    }
  } else {
    for k in 0..<3 {
      weights[k] = (Float::from_int(fine[k]) + weights[k]) * 0.125F -
        Float::from_int(base[k])
    }
  }
  let corners = []
  for z in 0..<2 {
    for y in 0..<2 {
      for x in 0..<2 {
        corners.push(
          read_texel(
            if is_fine {
              self.subgrid
            } else {
              self.coarse
            },
            shape,
            [origin[0] + x, origin[1] + y, origin[2] + z],
            self.paired_samples,
            if is_fine {
              self.texture_format
            } else {
              "float32"
            },
          ),
        )
      }
    }
  }
  (corners, weights, is_fine, diff)
}

///|
fn blend(c : Array[Float], t : Array[Float]) -> Float {
  let a = c[0] + (c[1] - c[0]) * t[0]
  let b = c[2] + (c[3] - c[2]) * t[0]
  let d = c[4] + (c[5] - c[4]) * t[0]
  let e = c[6] + (c[7] - c[6]) * t[0]
  let f = a + (b - a) * t[1]
  let g = d + (e - d) * t[1]
  f + (g - f) * t[2]
}

///|
/// Source software interpolation, normalized integer texture decode and
/// out-of-box distance extrapolation. shape_margin is a caller-time offset;
/// it is intentionally absent from persistent cooking/cache keys.
pub fn SparseSdf::sample(
  self : SparseSdf,
  position : Array[Double],
  shape_margin~ : Double = 0,
) -> Double raise {
  guard finite(shape_margin) else { fail("finite shape margin required") }
  let (c, t, fine, diff) = self.cell(position)
  let mut value = blend(c, t)
  if fine {
    value = value * Float::from_double(self.value_range) +
      Float::from_double(self.value_min)
  }
  let outside = Float::from_double(
    (diff[0] * diff[0] + diff[1] * diff[1] + diff[2] * diff[2])
    .to_double()
    .sqrt(),
  )
  let result = (value + outside).to_double() - shape_margin
  guard finite(result) else { fail("SDF interpolation overflow") }
  result
}

///|
/// Integer fine-grid vertex path used by source marching cubes. Fine slots
/// perform one exact point read; EMPTY/LINEAR slots use coarse interpolation.
pub fn SparseSdf::sample_voxel(
  self : SparseSdf,
  index : Array[Int32],
) -> Double raise {
  self.validate()
  guard index.length() == 3 &&
    [0, 1, 2].all(k => index[k] >= 0 && index[k] <= self.slot_shape[k] * 8) else {
    fail("SDF voxel index is outside domain")
  }
  let base = Array::makei(3, k => (index[k] / 8).min(self.slot_shape[k] - 1))
  let slot = word(
    self.slots,
    ((base[0] * self.slot_shape[1] + base[1]) * self.slot_shape[2] + base[2]) *
    4,
  )
  if slot < 0xfffffffeU {
    let location = Array::makei(3, k => {
      ((slot >> (10 * k)) & 1023U).to_int() * 9 + index[k] - base[k] * 8
    })
    let value = read_texel(
      self.subgrid,
      [self.texture_size, self.texture_size, self.texture_size],
      location,
      self.paired_samples,
      self.texture_format,
    )
    let result = (value * Float::from_double(self.value_range) +
    Float::from_double(self.value_min)).to_double()
    guard finite(result) else { fail("SDF voxel decode overflow") }
    result
  } else {
    self.sample(
      Array::makei(3, k => {
        (Float::from_double(self.lower[k]) +
        Float::from_int(index[k]) * Float::from_double(self.cell_size[k])).to_double()
      }),
    )
  }
}

///|
/// Port of texture_sample_sdf_grad, including the source's coarse-cell
/// gradient scaling convention. Hardware CUDA interpolation/FD is separate.
pub fn SparseSdf::sample_gradient(
  self : SparseSdf,
  position : Array[Double],
  shape_margin~ : Double = 0,
) -> SdfSample raise {
  guard finite(shape_margin) else { fail("finite shape margin required") }
  let (c, t, fine, diff) = self.cell(position)
  if fine {
    for k in 0..<8 {
      c[k] = c[k] * Float::from_double(self.value_range) +
        Float::from_double(self.value_min)
    }
  }
  let x = t[0]
  let y = t[1]
  let z = t[2]
  let ox = 1.0F - x
  let oy = 1.0F - y
  let oz = 1.0F - z
  let gx = oy * oz * (c[1] - c[0]) +
    y * oz * (c[3] - c[2]) +
    oy * z * (c[5] - c[4]) +
    y * z * (c[7] - c[6])
  let gy = ox * oz * (c[2] - c[0]) +
    x * oz * (c[3] - c[1]) +
    ox * z * (c[6] - c[4]) +
    x * z * (c[7] - c[5])
  let gz = ox * oy * (c[4] - c[0]) +
    x * oy * (c[5] - c[1]) +
    ox * y * (c[6] - c[2]) +
    x * y * (c[7] - c[3])
  let outside = Float::from_double(
    (diff[0] * diff[0] + diff[1] * diff[1] + diff[2] * diff[2])
    .to_double()
    .sqrt(),
  )
  let gradient = if outside > 0 {
    diff.map(v => (v / outside).to_double())
  } else {
    [gx, gy, gz].mapi((k, v) => {
      (v * Float::from_double(1.0 / self.cell_size[k])).to_double()
    })
  }
  let result = (blend(c, t) + outside).to_double() - shape_margin
  guard finite(result) && gradient.all(finite) else {
    fail("SDF gradient overflow")
  }
  { distance: result, gradient, }
}
