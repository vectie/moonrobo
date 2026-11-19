///|
struct DeviceOwners {
  context : @dispatch.Context
  host : HostLayout
  buffers : Map[String, @dispatch.Buffer]
  closed : Ref[Bool]
}

///|
/// Native Warp allocation owners, not a Newton Model/State/Control object.
/// Retain this owner and the actual borrowed CUDA context owner for every
/// graph/kernel that references these buffers. close is explicit and terminal.
pub struct DeviceLayout(DeviceOwners)

///|
/// Explicit execution: allocates device memory and uploads each real host
/// buffer through the existing Warp C ABI. No caller invokes it automatically.
/// The context is borrowed and is never closed by this function or its owner.
pub fn upload(
  host : HostLayout,
  context : @dispatch.Context,
) -> DeviceLayout raise {
  let buffers : Map[String, @dispatch.Buffer] = {}
  let owned_arrays : Map[String, HostArray] = {}
  let aliases : Map[String, ArrayAlias] = {}
  for key in host.aliases.keys() {
    ignore(host.resolve(key))
    let value = host.aliases[key]
    aliases[key] = { ..value, shape: value.shape.copy(), }
  }
  try {
    for name in host.array_names() {
      let array = host.array(name)
      array.validate()
      owned_arrays[name] = array
      if array.bytes.length() == 0 {
        continue
      }
      let buffer = context.allocate(array.bytes.length().to_uint64())
      buffers[name] = buffer
      // Buffer.write synchronizes before borrowed host storage is released.
      buffer.write(array.bytes)
    }
  } catch {
    error => {
      for buffer in buffers.values() {
        buffer.close()
      }
      raise error
    }
  }
  let snapshot = {
    ..host,
    arrays: owned_arrays,
    aliases,
    unresolved_semantics: host.unresolved_semantics.copy(),
  }
  DeviceLayout({ context, host: snapshot, buffers, closed: Ref(false), })
}

///|
pub fn DeviceLayout::argument(
  self : DeviceLayout,
  name : String,
) -> @dispatch.Argument raise {
  guard !self.0.closed.val else { fail("device layout is closed") }
  let (base, shape, components, offset, size) = self.0.host.resolve(name)
  guard size > 0 && self.0.buffers.get(base) is Some(buffer) else {
    fail("device layout is closed or array is absent")
  }
  let array = self.0.host.array(name)
  @dispatch.Argument::array(
    buffer,
    shape,
    array.strides(),
    (width(array.scalar_type) * components).reinterpret_as_uint(),
    offset=offset.to_uint64(),
  )
}

///|
pub fn DeviceLayout::pointer(
  self : DeviceLayout,
  name : String,
) -> UInt64 raise {
  guard !self.0.closed.val else { fail("device layout is closed") }
  let (base, _, _, offset, size) = self.0.host.resolve(name)
  if size == 0 {
    return 0UL
  }
  guard self.0.buffers.get(base) is Some(buffer) else {
    fail("device layout is closed or array is absent")
  }
  buffer.pointer() + offset.to_uint64()
}

///|
/// Explicit synchronized readback for later parity checks; never an automatic
/// constructor self-check or availability probe.
pub fn DeviceLayout::download(
  self : DeviceLayout,
  name : String,
) -> Bytes raise {
  guard !self.0.closed.val else { fail("device layout is closed") }
  let (base, _, _, offset, size) = self.0.host.resolve(name)
  if size == 0 {
    return b""
  }
  guard self.0.buffers.get(base) is Some(buffer) else {
    fail("device layout is closed or array is absent")
  }
  buffer.read(size, offset=offset.to_uint64())
}

///|
/// Wait for submitted work, then close this owner's child handles. The dispatch
/// arena can retain allocations until its last Context/Buffer/Kernel owner is
/// released. The caller still owns the Context and any graph references.
pub fn DeviceLayout::close(self : DeviceLayout) -> Unit raise {
  if self.0.closed.val {
    return
  }
  self.0.context.synchronize()
  for buffer in self.0.buffers.values() {
    buffer.close()
  }
  self.0.closed.val = true
}
