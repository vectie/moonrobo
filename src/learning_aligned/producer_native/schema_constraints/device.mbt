///|
pub struct DeviceArrays {
  priv context : @dispatch.Context
  priv buffers : Map[String, @dispatch.Buffer]
  priv arrays : Map[String, NumericArray]
  priv mut closed : Bool
}

///|
/// Explicitly upload real equality bytes through the existing native Warp C
/// allocation API. Caller owns context; close never closes that context.
pub fn upload(
  prepared : Prepared,
  context : @dispatch.Context,
) -> DeviceArrays raise {
  let buffers : Map[String, @dispatch.Buffer] = Map([])
  let arrays : Map[String, NumericArray] = Map([])
  errdefer (for buffer in buffers.values() {
    buffer.close()
  })
  for item in prepared.arrays {
    ignore(item.metadata())
    arrays[item.name] = item
    if !item.bytes.is_empty() {
      let buffer = context.allocate(item.bytes.length().to_uint64())
      buffers[item.name] = buffer
      buffer.write(item.bytes)
    }
  }
  { context, buffers, arrays, closed: false, }
}

///|
pub fn DeviceArrays::argument(
  self : DeviceArrays,
  name : String,
) -> @dispatch.Argument raise {
  guard !self.closed &&
    self.arrays.get(name) is Some(array) &&
    self.buffers.get(name) is Some(buffer) else {
    fail("constraint device array is closed, empty or unknown")
  }
  @dispatch.Argument::array(
    buffer,
    array.shape.copy(),
    array.strides(),
    (scalar_width(array.scalar_type) * array.components).reinterpret_as_uint(),
  )
}

///|
pub fn DeviceArrays::download(
  self : DeviceArrays,
  name : String,
) -> Bytes raise {
  guard !self.closed && self.arrays.get(name) is Some(array) else {
    fail("constraint device array is closed or unknown")
  }
  if array.bytes.is_empty() {
    b""
  } else {
    self.buffers[name].read(array.bytes.length())
  }
}

///|
pub fn DeviceArrays::close(self : DeviceArrays) -> Unit {
  // The retained caller-owned context is released only with this object.
  ignore(self.context)
  if !self.closed {
    for buffer in self.buffers.values() {
      buffer.close()
    }
    self.closed = true
  }
}
