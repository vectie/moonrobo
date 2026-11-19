///|
priv type NativeField

///|
#borrow(adapter, library, data, placement)
extern "c" fn field_open(
  adapter : Bytes,
  library : Bytes,
  kind : Int32,
  data : Bytes,
  nx : Int32,
  ny : Int32,
  nz : Int32,
  channels : Int32,
  dtype : Int32,
  placement : Bytes,
  background : Float,
) -> NativeField = "moonrobo_field_open"

///|
#borrow(field)
extern "c" fn field_error(field : NativeField) -> Bytes = "moonrobo_field_error"

///|
#borrow(field)
extern "c" fn field_id(field : NativeField, kind : Int32) -> UInt64 = "moonrobo_field_id"

///|
#borrow(field)
#owned(context)
extern "c" fn field_owner(
  field : NativeField,
  context : @dispatch.Context,
) -> Unit = "moonrobo_field_owner"

///|
#borrow(field)
extern "c" fn field_upload(
  field : NativeField,
  context : UInt64,
  stream : UInt64,
) -> Unit = "moonrobo_field_upload"

///|
#borrow(field)
extern "c" fn field_snapshot(field : NativeField) -> Bytes = "moonrobo_field_snapshot"

///|
#borrow(field)
extern "c" fn field_close(field : NativeField) -> Unit = "moonrobo_field_close"

///|
pub struct CookedField(FieldOwners)

///|
struct FieldOwners {
  native : NativeField
  kind : String
  shape : Array[Int32]
  channels : Int32
  format : String
  closed : Ref[Bool]
  context : Ref[@dispatch.Context?]
}

///|
fn CookedField::check(self : CookedField) -> Unit raise {
  guard !self.0.closed.val else { fail("cooked field is closed") }
  let error = @utf8.decode(field_error(self.0.native))
  guard error.is_empty() else { fail(error) }
}

///|
fn create_field(
  adapter : String,
  library : String,
  kind : Int32,
  data : Bytes,
  shape : Array[Int32],
  channels : Int32,
  format : String,
  placement : Bytes,
  background : Double,
) -> CookedField raise {
  guard !adapter.is_empty() &&
    !library.is_empty() &&
    !adapter.contains("\u{0}") &&
    !library.contains("\u{0}") &&
    shape.length() == 3 &&
    shape.all(n => n > 0 && n <= 256) &&
    finite(background) else {
    fail("invalid explicit field paths/dimensions/background")
  }
  let dtype = match format {
    "uint8" => 0
    "uint16" => 1
    "float32" => 2
    _ => fail("unsupported cooked field format")
  }
  let native = field_open(
    @utf8.encode(adapter),
    @utf8.encode(library),
    kind,
    data,
    shape[0],
    shape[1],
    shape[2],
    channels,
    dtype,
    placement,
    Float::from_double(background),
  )
  let result = CookedField({
    native,
    kind: if kind == 0 {
      "texture3d"
    } else {
      "nanovdb-float"
    },
    shape: shape.copy(),
    channels,
    format,
    closed: Ref(false),
    context: Ref(None),
  })
  errdefer result.close()
  result.check()
  guard field_id(native, 0) != 0UL else {
    fail("genuine host field ID is zero")
  }
  result
}

///|
/// Real Warp linear/clamp/non-normalized host Texture3D. shape is x,y,z;
/// contiguous bytes have x innermost, channels interleaved per voxel.
pub fn open_texture(
  adapter : String,
  library : String,
  data : Bytes,
  shape : Array[Int32],
  channels : Int32,
  format : String,
) -> CookedField raise {
  create_field(adapter, library, 0, data, shape, channels, format, b"", 0)
}

///|
/// Real native NanoVDB volume allocated by host tile builder and populated via
/// genuine volume_store_f. This is the legacy volume representation, separate
/// from current Newton's two-texture SDF. No fabricated NanoVDB blob is emitted.
pub fn open_volume(
  adapter : String,
  library : String,
  data : Bytes,
  shape : Array[Int32],
  cell_size : Array[Double],
  origin : Array[Double],
  background : Double,
) -> CookedField raise {
  guard cell_size.length() == 3 &&
    cell_size.all(x => finite(x) && x > 0) &&
    origin.length() == 3 &&
    origin.all(finite) else {
    fail("invalid explicit volume transform")
  }
  let placement = cell_size.copy()
  for x in origin {
    placement.push(x)
  }
  create_field(
    adapter,
    library,
    1,
    data,
    shape,
    1,
    "float32",
    floats(placement),
    background,
  )
}

///|
pub fn CookedField::host_id(self : CookedField) -> UInt64 raise {
  self.check()
  field_id(self.0.native, 0)
}

///|
pub fn CookedField::device_id(self : CookedField) -> UInt64 raise {
  self.check()
  guard self.0.context.val is Some(context) else {
    fail("field has not been explicitly uploaded")
  }
  ignore(context.pointer())
  field_id(self.0.native, 1)
}

///|
pub fn CookedField::snapshot(self : CookedField) -> Bytes raise {
  self.check()
  let bytes = field_snapshot(self.0.native)
  self.check()
  bytes
}

///|
/// Real CUDA array/object or NanoVDB device allocation. Retains a private
/// independent Device token through native destruction, including GC cleanup.
pub fn CookedField::upload(
  self : CookedField,
  context : @dispatch.Context,
) -> Unit raise {
  self.check()
  guard self.0.context.val is None else {
    fail("field already has a device resource")
  }
  let retained = context.retain()
  errdefer retained.close()
  field_owner(self.0.native, retained.retain())
  retained.synchronize()
  field_upload(self.0.native, retained.pointer(), retained.stream())
  self.check()
  guard field_id(self.0.native, 1) != 0UL else {
    fail("genuine device field ID is zero")
  }
  self.0.context.val = Some(retained)
}

///|
pub fn CookedField::metadata(self : CookedField) -> Json raise {
  self.check()
  {
    "format": "moonrobo.native-cooked-field-resource.v1",
    "kind": Json(self.0.kind),
    "shape_xyz": Json(self.0.shape),
    "channels": Json(self.0.channels),
    "scalar_format": Json(self.0.format),
    "host_id_decimal": Json(self.host_id().to_string()),
    "device_id_decimal": Json(field_id(self.0.native, 1).to_string()),
    "cuda_array_decimal": Json(field_id(self.0.native, 2).to_string()),
    "device_created": Json(self.0.context.val is Some(_)),
    "resource_id_serializable_for_reuse": false,
    "full_newton_cooking_complete": false,
    "numeric_equivalence_verified": false,
  }
}

///|
pub fn CookedField::close(self : CookedField) -> Unit {
  if !self.0.closed.val {
    field_close(self.0.native)
    if self.0.context.val is Some(context) {
      context.close()
    }
    self.0.closed.val = true
  }
}

///|
pub struct TextureSdf(TextureSdfOwners)

///|
struct TextureSdfOwners {
  coarse : CookedField
  subgrid : CookedField
  slots : @dispatch.Buffer
  context : @dispatch.Context
  metadata : Json
  slot_shape : Array[Int32]
  closed : Ref[Bool]
}

///|
/// Native CUDA resource port of create_sparse_sdf_textures. Indirection bytes
/// preserve actual [w,h,d] strides and EMPTY/LINEAR sentinels. Caller uses the
/// returned true resource IDs/array argument to pack its genuine kernel ABI.
pub fn SparseSdf::upload_textures(
  self : SparseSdf,
  adapter : String,
  library : String,
  context : @dispatch.Context,
) -> TextureSdf raise {
  self.validate_storage()
  let retained = context.retain()
  errdefer retained.close()
  let channels = if self.paired_samples { 2 } else { 1 }
  let shape = self.coarse_shape
  let coarse = open_texture(
    adapter,
    library,
    self.coarse,
    [shape[2], shape[1], shape[0]],
    channels,
    "float32",
  )
  errdefer coarse.close()
  let subgrid = open_texture(
    adapter,
    library,
    self.subgrid,
    [self.texture_size, self.texture_size, self.texture_size],
    channels,
    self.texture_format,
  )
  errdefer subgrid.close()
  coarse.upload(retained)
  subgrid.upload(retained)
  let slots = retained.allocate(self.slots.length().to_uint64())
  errdefer slots.close()
  slots.write(self.slots)
  TextureSdf({
    coarse,
    subgrid,
    slots,
    context: retained,
    metadata: self.metadata(),
    slot_shape: self.slot_shape.copy(),
    closed: Ref(false),
  })
}

///|
pub fn TextureSdf::coarse_id(self : TextureSdf) -> UInt64 raise {
  guard !self.0.closed.val else { fail("texture SDF is closed") }
  self.0.coarse.device_id()
}

///|
pub fn TextureSdf::subgrid_id(self : TextureSdf) -> UInt64 raise {
  guard !self.0.closed.val else { fail("texture SDF is closed") }
  self.0.subgrid.device_id()
}

///|
pub fn TextureSdf::slots_argument(
  self : TextureSdf,
) -> @dispatch.Argument raise {
  guard !self.0.closed.val else { fail("texture SDF is closed") }
  let shape = self.0.slot_shape.copy()
  @dispatch.Argument::array(
    self.0.slots,
    shape,
    [shape[1] * shape[2] * 4, shape[2] * 4, 4],
    4U,
  )
}

///|
pub fn TextureSdf::metadata(self : TextureSdf) -> Json raise {
  {
    "cooked": @json.parse(self.0.metadata.stringify()),
    "coarse_texture_decimal": Json(self.coarse_id().to_string()),
    "subgrid_texture_decimal": Json(self.subgrid_id().to_string()),
    "slot_pointer_decimal": Json(self.0.slots.pointer().to_string()),
    "actual_cuda_resources": true,
    "full_newton_cooking_complete": false,
  }
}

///|
pub fn TextureSdf::close(self : TextureSdf) -> Unit raise {
  if !self.0.closed.val {
    self.0.context.synchronize()
    self.0.coarse.close()
    self.0.subgrid.close()
    self.0.slots.close()
    self.0.context.close()
    self.0.closed.val = true
  }
}
