///|
/// Physical byte strides and compound element size observed by native SDK
/// metadata. Indexed/gathered views are refused unless separately materialized.
pub(all) struct RawView {
  address : UInt64
  shape : Array[Int32]
  byte_strides : Array[Int64]
  element_bytes : Int32
  scalar_type : ScalarType
  affine : Bool
} derive(Debug)

///|
/// Public JSON shape matches the existing APIC runtime manifest.
pub(all) struct BufferView {
  binding : String
  offset_elements : Int32
  row_stride_elements : Int32
  component_stride_elements : Int32
  width : Int32
} derive(Debug, Eq, ToJson, FromJson)

///|
fn NumericUnion::region(
  self : NumericUnion,
  name : String,
) -> NumericRegion raise ContractError {
  for region in self.regions {
    if region.name == name {
      return region
    }
  }
  raise Invalid("component binding is absent from numerical union")
}

///|
fn NumericUnion::containing(
  self : NumericUnion,
  address : UInt64,
) -> NumericRegion raise ContractError {
  for region in self.regions {
    if address >= region.address &&
      address - region.address < region.bytes.to_uint64() {
      return region
    }
  }
  raise Invalid("component address is absent from persistent numerical union")
}

///|
/// Every sum/product is checked against base element capacity *before*
/// multiplication; huge shape/stride metadata cannot overflow Int64.
pub fn BufferView::validate(
  self : BufferView,
  union : NumericUnion,
  rows : Int32,
) -> Unit raise ContractError {
  let region = union.region(self.binding)
  guard rows > 0 &&
    self.width > 0 &&
    self.offset_elements >= 0 &&
    self.row_stride_elements >= 0 &&
    self.component_stride_elements > 0 else {
    raise Invalid("component rows/width/offset/strides are invalid")
  }
  let capacity = region.bytes / region.scalar_bytes
  guard self.offset_elements < capacity else {
    raise Invalid("component offset is outside allocation")
  }
  let remaining = (capacity - 1 - self.offset_elements).to_int64()
  let components = (self.width - 1).to_int64()
  let stride = self.component_stride_elements.to_int64()
  guard components <= remaining / stride else {
    raise Invalid("component span reaches beyond allocation")
  }
  let tail = remaining - components * stride
  let row_stride = self.row_stride_elements.to_int64()
  guard row_stride == 0L || (rows - 1).to_int64() <= tail / row_stride else {
    raise Invalid("component row span reaches beyond allocation")
  }
}

///|
pub fn NumericUnion::view(
  self : NumericUnion,
  raw : RawView,
  width : Int32,
  rows : Int32,
) -> BufferView raise ContractError {
  guard raw.affine &&
    raw.shape.length() > 0 &&
    raw.shape.length() <= 2 &&
    raw.shape.length() == raw.byte_strides.length() &&
    raw.shape[0] == rows &&
    rows > 0 &&
    width > 0 else {
    raise Invalid("component requires a real affine one/two-axis SDK view")
  }
  guard raw.shape.all(fn(n) { n > 0 }) else {
    raise Invalid("component shape has nonpositive extent")
  }
  let region = self.containing(raw.address)
  guard raw.scalar_type == region.scalar_type &&
    raw.element_bytes > 0 &&
    raw.element_bytes % region.scalar_bytes == 0 else {
    raise Invalid("component dtype/compound size differs from owned base")
  }
  let offset = raw.address - region.address
  guard offset % region.scalar_bytes.to_uint64() == 0UL &&
    raw.byte_strides[0] >= 0L &&
    raw.byte_strides[0] % region.scalar_bytes.to_int64() == 0L else {
    raise Invalid("component offset/row byte stride is not scalar aligned")
  }
  let compound = raw.element_bytes / region.scalar_bytes
  let (logical_width, component_stride) = if raw.shape.length() == 2 {
    guard compound == 1 &&
      raw.byte_strides[1] > 0L &&
      raw.byte_strides[1] % region.scalar_bytes.to_int64() == 0L else {
      raise Invalid("matrix component stride/compound elements are unsupported")
    }
    let stride = raw.byte_strides[1] / region.scalar_bytes.to_int64()
    guard stride <= 2147483647L else {
      raise Invalid("component stride exceeds exact Int32 manifest range")
    }
    (raw.shape[1], stride.to_int())
  } else {
    (compound, 1)
  }
  guard logical_width == width else {
    raise Invalid("component width differs from SDK dtype/shape")
  }
  let row_stride = raw.byte_strides[0] / region.scalar_bytes.to_int64()
  guard row_stride <= 2147483647L else {
    raise Invalid("row stride exceeds exact Int32 manifest range")
  }
  let view : BufferView = {
    binding: region.name,
    offset_elements: (offset / region.scalar_bytes.to_uint64()).to_int(),
    row_stride_elements: row_stride.to_int(),
    component_stride_elements: component_stride,
    width,
  }
  view.validate(self, rows)
  view
}

///|
/// Bounds are required even for callers passing a reconstructed JSON view.
pub fn BufferView::index(
  self : BufferView,
  union : NumericUnion,
  rows : Int32,
  row : Int32,
  component : Int32,
) -> Int32 raise ContractError {
  self.validate(union, rows)
  guard row >= 0 && row < rows && component >= 0 && component < self.width else {
    raise Invalid("component index outside logical shape")
  }
  // validate() proved this complete sum is below exact Int32 capacity.
  self.offset_elements +
  row * self.row_stride_elements +
  component * self.component_stride_elements
}

///|
/// Fixed original robot binding contract. Inputs cannot alias state or each
/// other, and every writable world's row must occupy disjoint storage.
pub fn NumericUnion::validate_components(
  self : NumericUnion,
  views : Map[String, BufferView],
  rows : Int32,
) -> Unit raise ContractError {
  let widths : Map[String, Int32] = Map([
    ("root_pose", 7),
    ("root_com_velocity", 6),
    ("root_com_local", 3),
    ("joint_position", 29),
    ("joint_velocity", 29),
    ("targets", 29),
    ("reset_pose", 7),
    ("reset_velocity", 6),
    ("reset_joint_position", 29),
    ("reset_joint_velocity", 29),
    ("reset_mask", 1),
  ])
  guard views.length() == widths.length() else {
    raise Invalid(
      "unexpected or missing original articulation component binding",
    )
  }
  for name, width in widths {
    guard views.get(name) is Some(view) && view.width == width else {
      raise Invalid("component binding width is missing or incorrect: " + name)
    }
    view.validate(self, rows)
    guard self.region(view.binding).scalar_type ==
      (if name == "reset_mask" { Bool8 } else { F32 }) else {
      raise Invalid("original articulation component scalar type differs")
    }
  }
  let state = [
    "root_pose", "root_com_velocity", "root_com_local", "joint_position", "joint_velocity",
  ].map(fn(name) { views.get(name).unwrap().binding })
  let inputs : Array[String] = []
  for
    name in [
      "targets", "reset_pose", "reset_velocity", "reset_joint_position", "reset_joint_velocity",
      "reset_mask",
    ] {
    let view = views.get(name).unwrap()
    guard !inputs.contains(view.binding) &&
      !state.contains(view.binding) &&
      view.row_stride_elements.to_int64() >
      (view.width - 1).to_int64() * view.component_stride_elements.to_int64() else {
      raise Invalid(
        "input bindings alias state/another input or overlapping world rows",
      )
    }
    inputs.push(view.binding)
  }
}
