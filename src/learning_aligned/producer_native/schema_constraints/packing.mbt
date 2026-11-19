///|
fn scalar_width(kind : String) -> Int32 raise {
  match kind {
    "bool" => 1
    "i32" | "f32" => 4
    "f64" => 8
    _ => fail("unsupported constraint array dtype")
  }
}

///|
fn append32(bytes : Array[Byte], value : UInt32) -> Unit {
  for i in 0..<4 {
    bytes.push(((value >> (8 * i)) & 255U).to_byte())
  }
}

///|
fn rounded(value : Double) -> Double raise {
  let result = Float::from_double(value)
  guard finite(value) && !result.is_nan() && !result.is_inf() else {
    fail("constraint float32 value overflows or is not finite")
  }
  result.to_double()
}

///|
fn vector(
  values : Array[Double]?,
  defaults : Array[Double],
  width : Int32,
) -> Array[Double] raise {
  let result = values.unwrap_or(defaults)
  guard result.length() == width else {
    fail("constraint vector has incorrect length")
  }
  result.map(rounded)
}

///|
fn floats(
  name : String,
  values : Array[Double],
  shape : Array[Int32],
  components : Int32,
  kind~ : String = "f32",
) -> NumericArray raise {
  let bytes = []
  for value in values {
    guard finite(value) else { fail("constraint numeric data is not finite") }
    if kind == "f32" {
      append32(bytes, Float::from_double(rounded(value)).reinterpret_as_uint())
    } else {
      guard kind == "f64" else { fail("unsupported floating storage type") }
      let bits = value.reinterpret_as_int64().reinterpret_as_uint64()
      for i in 0..<8 {
        bytes.push(((bits >> (8 * i)) & 255UL).to_byte())
      }
    }
  }
  let result = {
    name,
    scalar_type: kind,
    shape,
    components,
    bytes: Bytes::from_array(bytes),
  }
  ignore(result.metadata())
  result
}

///|
fn ints(name : String, values : Array[Int32]) -> NumericArray {
  let bytes = []
  for value in values {
    append32(bytes, value.reinterpret_as_uint())
  }
  {
    name,
    scalar_type: "i32",
    shape: [values.length()],
    components: 1,
    bytes: Bytes::from_array(bytes),
  }
}

///|
fn booleans(name : String, values : Array[Bool]) -> NumericArray {
  {
    name,
    scalar_type: "bool",
    shape: [values.length()],
    components: 1,
    bytes: Bytes::from_array(values.map(v => if v { b'\x01' } else { b'\x00' })),
  }
}

///|
fn NumericArray::strides(self : NumericArray) -> Array[Int32] raise {
  guard self.shape.length() >= 1 &&
    self.shape.length() <= 4 &&
    self.components >= 1 &&
    self.components <= 16 else {
    fail("invalid constraint rank/components")
  }
  let result = Array::make(self.shape.length(), 0)
  let mut stride = scalar_width(self.scalar_type) * self.components
  for i = self.shape.length() - 1; i >= 0; i = i - 1 {
    result[i] = stride
    guard self.shape[i] >= 0 &&
      (self.shape[i] == 0 || stride <= 268435456 / self.shape[i]) else {
      fail("constraint array storage exceeds 256 MiB")
    }
    stride *= self.shape[i]
  }
  guard stride == self.bytes.length() else {
    fail("constraint raw bytes do not match shape/components")
  }
  result
}

///|
pub fn NumericArray::metadata(self : NumericArray) -> Json raise {
  let strides = self.strides()
  {
    "name": Json(self.name),
    "scalar_type": Json(self.scalar_type),
    "shape": Json(self.shape),
    "components": Json(self.components),
    "strides_bytes": Json(strides),
    "byte_length": Json(self.bytes.length()),
    "byte_order": "little",
    "sha256": Json(@artifacts.sha256(self.bytes)),
  }
}
