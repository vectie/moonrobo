///|
fn width(kind : String) -> Int32 raise {
  match kind {
    "bool" => 1
    "i32" | "f32" => 4
    "f64" | "i64" | "u64" => 8
    _ => fail("unsupported rigid layout scalar type")
  }
}

///|
fn array_count(shape : Array[Int32], components : Int32) -> Int32 raise {
  guard shape.length() >= 1 &&
    shape.length() <= 4 &&
    components > 0 &&
    components <= 16 else {
    fail("invalid typed array rank or component count")
  }
  let mut count = components
  for extent in shape {
    guard extent >= 0 && (extent == 0 || count <= 2147483647 / extent) else {
      fail("typed array element count overflows")
    }
    count *= extent
  }
  count
}

///|
fn HostArray::validate(self : HostArray) -> Unit raise {
  let count = array_count(self.shape, self.components)
  let size = width(self.scalar_type)
  guard count <= 2147483647 / size && self.bytes.length() == count * size else {
    fail("typed host array byte length does not match its shape and dtype")
  }
}

///|
fn append32(out : Array[Byte], value : UInt32) -> Unit {
  for i in 0..<4 {
    out.push(((value >> (8 * i)) & 255U).to_byte())
  }
}

///|
fn append64(out : Array[Byte], value : UInt64) -> Unit {
  for i in 0..<8 {
    out.push(((value >> (8 * i)) & 255UL).to_byte())
  }
}

///|
fn integers(
  values : Array[Int32],
  shape : Array[Int32],
  components~ : Int32 = 1,
) -> HostArray raise {
  guard array_count(shape, components) == values.length() &&
    values.length() <= 2147483647 / 4 else {
    fail("integer array shape/byte count mismatch")
  }
  let out = []
  for value in values {
    append32(out, value.reinterpret_as_uint())
  }
  {
    scalar_type: "i32",
    shape: shape.copy(),
    components,
    bytes: Bytes::from_array(out),
  }
}

///|
fn floating(
  values : Array[Double],
  shape : Array[Int32],
  kind : String,
  components~ : Int32 = 1,
) -> HostArray raise {
  guard (kind == "f32" || kind == "f64") &&
    array_count(shape, components) == values.length() &&
    values.length() <= 2147483647 / width(kind) else {
    fail("floating array shape/byte count mismatch")
  }
  let out = []
  for value in values {
    guard !value.is_nan() && !value.is_inf() else {
      fail("nonfinite value in rigid layout")
    }
    if kind == "f32" {
      let converted = Float::from_double(value)
      guard !converted.is_nan() && !converted.is_inf() else {
        fail("float32 conversion overflow")
      }
      guard value == 0.0 || converted != 0.0 else {
        fail("float32 conversion underflow to zero")
      }
      append32(out, converted.reinterpret_as_uint())
    } else {
      append64(out, value.reinterpret_as_int64().reinterpret_as_uint64())
    }
  }
  {
    scalar_type: kind,
    shape: shape.copy(),
    components,
    bytes: Bytes::from_array(out),
  }
}

///|
fn HostArray::strides(self : HostArray) -> Array[Int32] raise {
  self.validate()
  let strides = Array::make(self.shape.length(), 0)
  let mut stride = width(self.scalar_type) * self.components
  for i = self.shape.length() - 1; i >= 0; i = i - 1 {
    strides[i] = stride
    guard self.shape[i] == 0 || stride <= 2147483647 / self.shape[i] else {
      fail("typed array byte stride overflows")
    }
    stride *= self.shape[i]
  }
  strides
}

///|
pub fn HostArray::metadata(self : HostArray) -> Json raise {
  self.validate()
  {
    "scalar_type": Json(self.scalar_type),
    "shape": Json(self.shape),
    "components": Json(self.components),
    "strides_bytes": Json(self.strides()),
    "element_bytes": Json(width(self.scalar_type) * self.components),
    "byte_length": Json(self.bytes.length()),
    "sha256": Json(@artifacts.sha256(self.bytes)),
    "byte_order": "little",
  }
}

///|
pub fn HostLayout::array(self : HostLayout, name : String) -> HostArray raise {
  let (base, shape, components, offset, size) = self.resolve(name)
  let array = self.arrays[base]
  {
    scalar_type: array.scalar_type,
    shape,
    components,
    bytes: array.bytes[offset:offset + size].to_owned(),
  }
}

///|
fn HostLayout::resolve(
  self : HostLayout,
  name : String,
) -> (String, Array[Int32], Int32, Int32, Int32) raise {
  if self.arrays.get(name) is Some(array) {
    array.validate()
    guard !self.aliases.contains(name) else {
      fail("alias shadows a physical array")
    }
    return (name, array.shape.copy(), array.components, 0, array.bytes.length())
  }
  guard self.aliases.get(name) is Some(view) &&
    self.arrays.get(view.base) is Some(base) else {
    fail("unknown or nonphysical typed array alias: " + name)
  }
  base.validate()
  let count = array_count(view.shape, view.components)
  let element = width(base.scalar_type) * view.components
  guard count <= 2147483647 / width(base.scalar_type) else {
    fail("alias byte size overflows")
  }
  let size = count * width(base.scalar_type)
  guard view.offset_bytes >= 0 &&
    view.offset_bytes % element == 0 &&
    view.offset_bytes <= base.bytes.length() &&
    size <= base.bytes.length() - view.offset_bytes else {
    fail("typed alias is misaligned or outside its physical owner")
  }
  (view.base, view.shape.copy(), view.components, view.offset_bytes, size)
}

///|
pub fn HostLayout::view_names(self : HostLayout) -> Array[String] {
  let names = self.array_names()
  for key in self.aliases.keys() {
    names.push(key)
  }
  names.sort()
  names
}

///|
pub fn HostLayout::array_names(self : HostLayout) -> Array[String] {
  let names = self.arrays.keys().collect()
  names.sort()
  names
}
