///|
type Handle

///|
/// Resource arena. Children retain its native allocations and module images.
pub struct Context(Handle)

///|
pub struct Buffer(Handle)

///|
pub struct Kernel(Handle)

///|
#borrow(plugin, warp)
extern "c" fn open_ffi(
  plugin : Bytes,
  warp : Bytes,
  context : UInt64,
  stream : UInt64,
  arch : Int32,
  ordinal : Int32,
) -> Handle = "moonrobo_dispatch_open"

///|
#borrow(handle)
extern "c" fn error_ffi(handle : Handle) -> Bytes = "moonrobo_dispatch_error"

///|
#borrow(handle)
extern "c" fn close_ffi(handle : Handle) -> Unit = "moonrobo_dispatch_close"

///|
#borrow(handle)
extern "c" fn retain_ffi(handle : Handle) -> Handle = "moonrobo_dispatch_retain"

///|
/// Independent token retaining the same native arena and owning CUDA context.
/// Closing another Context token cannot destroy this token's Device. For an
/// externally borrowed CUDA context, its real external owner must still live.
/// Requires additive mrd_context_retain; older ABI-3 plugins fail explicitly.
pub fn Context::retain(self : Context) -> Context raise {
  self.0.checked()
  let handle = retain_ffi(self.0)
  handle.checked()
  Context(handle)
}

///|
#borrow(handle)
extern "c" fn context_ffi(handle : Handle) -> UInt64 = "moonrobo_dispatch_context"

///|
#borrow(handle)
extern "c" fn stream_ffi(handle : Handle) -> UInt64 = "moonrobo_dispatch_stream"

///|
#borrow(handle)
extern "c" fn arch_ffi(handle : Handle) -> Int32 = "moonrobo_dispatch_arch"

///|
#borrow(handle)
extern "c" fn sync_ffi(handle : Handle) -> Int32 = "moonrobo_dispatch_sync"

///|
#borrow(handle)
extern "c" fn external_copy_ffi(
  handle : Handle,
  destination : UInt64,
  source : UInt64,
  count : UInt64,
  state : UInt64,
) -> Int32 = "moonrobo_dispatch_external_copy"

///|
#borrow(handle)
extern "c" fn external_zero_ffi(
  handle : Handle,
  pointer : UInt64,
  count : UInt64,
  state : UInt64,
) -> Int32 = "moonrobo_dispatch_external_zero"

///|
#borrow(handle)
extern "c" fn allocate_ffi(handle : Handle, count : UInt64) -> Handle = "moonrobo_dispatch_allocate"

///|
#borrow(handle)
extern "c" fn pointer_ffi(handle : Handle) -> UInt64 = "moonrobo_dispatch_buffer_pointer"

///|
#borrow(handle)
extern "c" fn size_ffi(handle : Handle) -> UInt64 = "moonrobo_dispatch_buffer_size"

///|
#borrow(handle, bytes)
extern "c" fn write_ffi(
  handle : Handle,
  offset : UInt64,
  bytes : Bytes,
) -> Int32 = "moonrobo_dispatch_write"

///|
#borrow(handle)
extern "c" fn read_ffi(
  handle : Handle,
  offset : UInt64,
  count : Int32,
) -> Bytes = "moonrobo_dispatch_read"

///|
#borrow(handle, path, name, hash, key, forward, backward)
extern "c" fn load_ffi(
  handle : Handle,
  path : Bytes,
  name : Bytes,
  hash : Bytes,
  key : Bytes,
  forward : Bytes,
  backward : Bytes,
  forward_smem : Int32,
  backward_smem : Int32,
  block : Int32,
  dim : Int32,
) -> Handle = "moonrobo_dispatch_load"

///|
#borrow(handle, wire, buffers)
extern "c" fn launch_ffi(
  handle : Handle,
  wire : Bytes,
  buffers : FixedArray[Handle],
  state : UInt64,
) -> Int32 = "moonrobo_dispatch_launch"

///|
fn Handle::checked(self : Handle, status~ : Int32 = 0) -> Unit raise {
  let error = @utf8.decode_lossy(error_ffi(self))
  guard status == 0 && error == "" else {
    fail("native Warp dispatch: " + error)
  }
}

///|
/// Borrow an initialized upstream CUDA context/stream. Never calls wp_init.
/// The external context and graph owners must outlive this handle and children.
pub fn Context::borrow(
  plugin : String,
  warp_library : String,
  context : UInt64,
  stream : UInt64,
  arch~ : Int32 = 0,
) -> Context raise {
  let handle = open_ffi(
    @utf8.encode(plugin),
    @utf8.encode(warp_library),
    context,
    stream,
    arch,
    -1,
  )
  handle.checked()
  Context(handle)
}

///|
/// Explicit offline initialization, context and stream creation. Not a probe.
pub fn Context::create(
  plugin : String,
  warp_library : String,
  device_ordinal : Int32,
) -> Context raise {
  guard device_ordinal >= 0 else { fail("negative CUDA ordinal") }
  let handle = open_ffi(
    @utf8.encode(plugin),
    @utf8.encode(warp_library),
    0UL,
    0UL,
    0,
    device_ordinal,
  )
  handle.checked()
  Context(handle)
}

///|
pub fn Context::pointer(self : Context) -> UInt64 raise {
  let value = context_ffi(self.0)
  self.0.checked()
  value
}

///|
pub fn Context::stream(self : Context) -> UInt64 raise {
  let value = stream_ffi(self.0)
  self.0.checked()
  value
}

///|
pub fn Context::synchronize(self : Context) -> Unit raise {
  self.0.checked(status=sync_ffi(self.0))
}

///|
pub fn Context::close(self : Context) -> Unit {
  close_ffi(self.0)
}

///|
/// External storage remains owned by caller. Both spans must be validated,
/// retained, same-context buffers already registered by the active recorder.
pub fn Context::copy_external(
  self : Context,
  destination : UInt64,
  source : UInt64,
  count : UInt64,
  capture_state~ : UInt64 = 0UL,
) -> Unit raise {
  self.0.checked(
    status=external_copy_ffi(self.0, destination, source, count, capture_state),
  )
}

///|
/// Calls Warp's APIC-aware wp_memset_device, never raw CUDA memset.
pub fn Context::zero_external(
  self : Context,
  pointer : UInt64,
  count : UInt64,
  capture_state~ : UInt64 = 0UL,
) -> Unit raise {
  self.0.checked(
    status=external_zero_ffi(self.0, pointer, count, capture_state),
  )
}

///|
pub fn Context::allocate(self : Context, count : UInt64) -> Buffer raise {
  self.0.checked()
  let handle = allocate_ffi(self.0, count)
  handle.checked()
  Buffer(handle)
}

///|
pub fn Buffer::pointer(self : Buffer) -> UInt64 raise {
  let value = pointer_ffi(self.0)
  self.0.checked()
  value
}

///|
pub fn Buffer::size(self : Buffer) -> UInt64 raise {
  let value = size_ffi(self.0)
  self.0.checked()
  value
}

///|
/// Upload synchronizes before releasing the borrowed host bytes; outside capture.
pub fn Buffer::write(
  self : Buffer,
  bytes : Bytes,
  offset~ : UInt64 = 0UL,
) -> Unit raise {
  self.0.checked(status=write_ffi(self.0, offset, bytes))
}

///|
pub fn Buffer::read(
  self : Buffer,
  count : Int32,
  offset~ : UInt64 = 0UL,
) -> Bytes raise {
  guard count >= 0 else { fail("negative download length") }
  let result = read_ffi(self.0, offset, count)
  self.0.checked()
  result
}

///|
pub fn Buffer::close(self : Buffer) -> Unit {
  close_ffi(self.0)
}

///|
/// Load a genuine compiled CUDA image and resolve its actual entrypoints.
/// Shared-memory sizes/block dimension must match the compiled specialization.
pub fn Context::load_kernel(
  self : Context,
  path : String,
  module_name : String,
  module_hash : String,
  kernel_key : String,
  forward_name : String,
  kernel_dim~ : Int32,
  backward_name~ : String = "",
  forward_smem~ : Int32 = 0,
  backward_smem~ : Int32 = 0,
  block_dim~ : Int32 = 256,
) -> Kernel raise {
  self.0.checked()
  let handle = load_ffi(
    self.0,
    @utf8.encode(path),
    @utf8.encode(module_name),
    @utf8.encode(module_hash),
    @utf8.encode(kernel_key),
    @utf8.encode(forward_name),
    @utf8.encode(backward_name),
    forward_smem,
    backward_smem,
    block_dim,
    kernel_dim,
  )
  handle.checked()
  Kernel(handle)
}

///|
pub fn Kernel::close(self : Kernel) -> Unit {
  close_ffi(self.0)
}

///|
pub fn Context::architecture(self : Context) -> Int32 raise {
  let value = arch_ffi(self.0)
  self.0.checked()
  value
}
