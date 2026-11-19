///|
/// Explicit offline Warp authoring handle. Borrowed graph/state/context lifetimes
/// remain owned by the caller. All methods must run on the opening OS thread.
pub type Writer

///|
#borrow(plugin, library)
extern "c" fn open_ffi(
  plugin : Bytes,
  library : Bytes,
  state : UInt64,
  context : UInt64,
  stream : UInt64,
  arch : Int32,
  owned : Int32,
) -> Writer = "moonrobo_warp_writer_open"

///|
#borrow(handle)
extern "c" fn error_ffi(handle : Writer) -> Bytes = "moonrobo_warp_writer_error"

///|
#borrow(handle)
extern "c" fn version_ffi(handle : Writer) -> Bytes = "moonrobo_warp_writer_version"

///|
#borrow(handle)
extern "c" fn library_ffi(handle : Writer) -> Bytes = "moonrobo_warp_writer_library"

///|
#borrow(handle)
extern "c" fn close_ffi(handle : Writer) -> Int32 = "moonrobo_warp_writer_close"

///|
#borrow(handle)
extern "c" fn begin_ffi(handle : Writer) -> Int32 = "moonrobo_warp_writer_begin"

///|
#borrow(handle)
extern "c" fn end_ffi(handle : Writer) -> Int32 = "moonrobo_warp_writer_end"

///|
#borrow(handle)
extern "c" fn count_ffi(handle : Writer) -> UInt32 = "moonrobo_warp_writer_count"

///|
#borrow(handle)
extern "c" fn state_ffi(handle : Writer) -> UInt64 = "moonrobo_warp_writer_state"

///|
#borrow(handle)
extern "c" fn region_ffi(
  handle : Writer,
  pointer : UInt64,
  capacity : UInt64,
  element : UInt32,
) -> UInt32 = "moonrobo_warp_writer_region"

///|
#borrow(handle)
extern "c" fn snapshot_ffi(
  handle : Writer,
  region : UInt32,
  pointer : UInt64,
  capacity : UInt64,
  element : UInt32,
  transient : Int32,
) -> Int32 = "moonrobo_warp_writer_snapshot"

///|
#borrow(handle, hash, name, binary)
extern "c" fn module_ffi(
  handle : Writer,
  hash : Bytes,
  name : Bytes,
  binary : Bytes,
) -> Int32 = "moonrobo_warp_writer_module"

///|
#borrow(handle, key, hash, forward, backward)
extern "c" fn kernel_ffi(
  handle : Writer,
  key : Bytes,
  hash : Bytes,
  forward : Bytes,
  backward : Bytes,
  forward_smem : Int32,
  backward_smem : Int32,
  block : Int32,
) -> Int32 = "moonrobo_warp_writer_kernel"

///|
#borrow(handle, name)
extern "c" fn binding_ffi(
  handle : Writer,
  name : Bytes,
  region : UInt32,
) -> Int32 = "moonrobo_warp_writer_binding"

///|
#borrow(handle)
extern "c" fn pointer_ffi(
  handle : Writer,
  region : UInt32,
  offset : UInt64,
  stride : UInt64,
) -> Int32 = "moonrobo_warp_writer_pointer"

///|
#borrow(handle)
extern "c" fn mesh_ffi(handle : Writer, mesh : UInt64) -> Int32 = "moonrobo_warp_writer_mesh"

///|
#borrow(handle, path)
extern "c" fn save_ffi(handle : Writer, path : Bytes) -> Int32 = "moonrobo_warp_writer_save"

///|
#borrow(handle, bytes)
extern "c" fn host_ffi(
  handle : Writer,
  bytes : Bytes,
  element : UInt32,
) -> UInt32 = "moonrobo_warp_writer_host"

///|
#borrow(handle)
extern "c" fn host_pointer_ffi(handle : Writer, region : UInt32) -> UInt64 = "moonrobo_warp_writer_host_pointer"

///|
#borrow(handle)
extern "c" fn memset_ffi(
  handle : Writer,
  region : UInt32,
  offset : UInt64,
  value : Int32,
  count : UInt64,
) -> Int32 = "moonrobo_warp_writer_memset"

///|
#borrow(handle)
extern "c" fn copy_ffi(
  handle : Writer,
  destination : UInt32,
  destination_offset : UInt64,
  source : UInt32,
  source_offset : UInt64,
  count : UInt64,
) -> Int32 = "moonrobo_warp_writer_copy"

///|
fn Writer::check(self : Writer, status : Int32) -> Unit raise {
  let message = @utf8.decode_lossy(error_ffi(self))
  if status != 0 || message != "" {
    fail("Warp authoring: " + message)
  }
}

///|
/// Does not initialize Warp or begin/end recording, and never destroys the
/// borrowed APIC state. The supplied library must be the capture's live library.
pub fn Writer::borrow(
  plugin_path : String,
  warp_library : String,
  state : UInt64,
  context : UInt64,
  stream : UInt64,
  arch : Int32,
) -> Writer raise {
  let writer = open_ffi(
    @utf8.encode(plugin_path),
    @utf8.encode(warp_library),
    state,
    context,
    stream,
    arch,
    0,
  )
  writer.check(0)
  writer
}

///|
/// Own a new state; explicit offline operation that initializes pinned Warp.
/// CPU uses zero context/stream/arch; CUDA contexts remain caller-owned.
pub fn Writer::create(
  plugin_path : String,
  warp_library : String,
  context~ : UInt64 = 0UL,
  stream~ : UInt64 = 0UL,
  arch~ : Int32 = 0,
) -> Writer raise {
  let writer = open_ffi(
    @utf8.encode(plugin_path),
    @utf8.encode(warp_library),
    0UL,
    context,
    stream,
    arch,
    1,
  )
  writer.check(0)
  writer
}

///|
pub fn Writer::version(self : Writer) -> String raise {
  let result = @utf8.decode_lossy(version_ffi(self))
  self.check(0)
  result
}

///|
pub fn Writer::library(self : Writer) -> String raise {
  let result = @utf8.decode_lossy(library_ffi(self))
  self.check(0)
  result
}

///|
pub fn Writer::close(self : Writer) -> Unit raise {
  let status = close_ffi(self)
  if status != 0 {
    self.check(status)
  }
}

///|
pub fn Writer::begin(self : Writer) -> Unit raise {
  self.check(begin_ffi(self))
}

///|
pub fn Writer::end(self : Writer) -> Unit raise {
  self.check(end_ffi(self))
}

///|
pub fn Writer::operation_count(self : Writer) -> UInt32 raise {
  let count = count_ffi(self)
  self.check(0)
  count
}

///|
pub fn Writer::register_region(
  self : Writer,
  pointer : UInt64,
  capacity : UInt64,
  element_size~ : UInt32 = 1U,
) -> UInt32 raise {
  let region = region_ffi(self, pointer, capacity, element_size)
  self.check(if region == 0U { -1 } else { 0 })
  region
}

///|
pub fn Writer::snapshot_region(
  self : Writer,
  region : UInt32,
  pointer : UInt64,
  capacity : UInt64,
  transient~ : Bool = false,
  element_size~ : UInt32 = 1U,
) -> Unit raise {
  self.check(
    snapshot_ffi(
      self,
      region,
      pointer,
      capacity,
      element_size,
      if transient {
        1
      } else {
        0
      },
    ),
  )
}

///|
pub fn Writer::register_module(
  self : Writer,
  hash : String,
  name : String,
  binary_filename : String,
) -> Unit raise {
  self.check(
    module_ffi(
      self,
      @utf8.encode(hash),
      @utf8.encode(name),
      @utf8.encode(binary_filename),
    ),
  )
}

///|
pub fn Writer::register_kernel(
  self : Writer,
  key : String,
  module_hash : String,
  forward : String,
  backward : String,
  forward_smem : Int32,
  backward_smem : Int32,
  block_dim : Int32,
) -> Unit raise {
  self.check(
    kernel_ffi(
      self,
      @utf8.encode(key),
      @utf8.encode(module_hash),
      @utf8.encode(forward),
      @utf8.encode(backward),
      forward_smem,
      backward_smem,
      block_dim,
    ),
  )
}

///|
pub fn Writer::register_binding(
  self : Writer,
  name : String,
  region : UInt32,
) -> Unit raise {
  self.check(binding_ffi(self, @utf8.encode(name), region))
}

///|
pub fn Writer::register_pointer_location(
  self : Writer,
  region : UInt32,
  offset : UInt64,
  stride : UInt64,
) -> Unit raise {
  self.check(pointer_ffi(self, region, offset, stride))
}

///|
pub fn Writer::register_mesh(self : Writer, mesh : UInt64) -> Unit raise {
  self.check(mesh_ffi(self, mesh))
}

///|
pub fn Writer::save(self : Writer, path : String) -> Unit raise {
  self.check(save_ffi(self, @utf8.encode(path)))
}

///|
/// Copy initial bytes to native-owned stable storage before CPU recording.
pub fn Writer::host_region(
  self : Writer,
  bytes : Bytes,
  element_size~ : UInt32 = 1U,
) -> UInt32 raise {
  let region = host_ffi(self, bytes, element_size)
  self.check(if region == 0U { -1 } else { 0 })
  region
}

///|
pub fn Writer::host_pointer(self : Writer, region : UInt32) -> UInt64 raise {
  let pointer = host_pointer_ffi(self, region)
  self.check(0)
  pointer
}

///|
/// Calls real wp_memset_host while owned CPU capture is active.
pub fn Writer::host_memset(
  self : Writer,
  region : UInt32,
  offset : UInt64,
  value : Int32,
  count : UInt64,
) -> Unit raise {
  self.check(memset_ffi(self, region, offset, value, count))
}

///|
/// Calls real wp_memcpy_h2h while owned CPU capture is active.
pub fn Writer::host_copy(
  self : Writer,
  destination : UInt32,
  destination_offset : UInt64,
  source : UInt32,
  source_offset : UInt64,
  count : UInt64,
) -> Unit raise {
  self.check(
    copy_ffi(
      self, destination, destination_offset, source, source_offset, count,
    ),
  )
}

///|
/// Borrow the actual recording pointer while keeping this Writer alive.
/// Pass it only to operations using the exact same loaded Warp library.
pub fn Writer::state_pointer(self : Writer) -> UInt64 raise {
  let pointer = state_ffi(self)
  self.check(0)
  pointer
}
