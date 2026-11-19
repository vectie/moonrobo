///|
/// Pointer slots inside an explicitly supplied by-value argument blob.
pub enum Relocation {
  Data(UInt32, Buffer, UInt64)
  ExternalHandle(UInt32, UInt64)
  Null(UInt32)
}

///|
pub enum Argument {
  Value(Bytes, UInt32, Array[Relocation])
  ArrayView(Buffer, Array[Int32], Array[Int32], UInt32, UInt64, Buffer?, UInt64)
}

///|
pub fn Relocation::data(
  slot : UInt32,
  buffer : Buffer,
  offset~ : UInt64 = 0UL,
) -> Relocation {
  Data(slot, buffer, offset)
}

///|
/// Caller must retain the actual upstream mesh/handle owner through graph use.
pub fn Relocation::external_handle(
  slot : UInt32,
  handle : UInt64,
) -> Relocation {
  ExternalHandle(slot, handle)
}

///|
pub fn Relocation::null_pointer(slot : UInt32) -> Relocation {
  Null(slot)
}

///|
/// Exact compiler-declared by-value layout. All pointer fields must have an
/// explicit relocation; this API cannot infer pointers from opaque bytes.
pub fn Argument::value_blob(
  bytes : Bytes,
  alignment : UInt32,
  relocations~ : Array[Relocation] = [],
) -> Argument {
  Value(bytes, alignment, relocations)
}

///|
fn append_u32(bytes : Array[Byte], value : UInt32) -> Unit {
  for i in 0..<4 {
    bytes.push(((value >> (i * 8)) & 255U).to_byte())
  }
}

///|
fn append_u64(bytes : Array[Byte], value : UInt64) -> Unit {
  for i in 0..<8 {
    bytes.push(((value >> (i * 8)) & 255UL).to_byte())
  }
}

///|
fn scalar32(bits : UInt32) -> Argument {
  let out = []
  append_u32(out, bits)
  Value(Bytes::from_array(out), 4U, [])
}

///|
fn scalar64(bits : UInt64) -> Argument {
  let out = []
  append_u64(out, bits)
  Value(Bytes::from_array(out), 8U, [])
}

///|
pub fn Argument::int32(value : Int32) -> Argument {
  scalar32(value.reinterpret_as_uint())
}

///|
pub fn Argument::uint32(value : UInt32) -> Argument {
  scalar32(value)
}

///|
pub fn Argument::int64(value : Int64) -> Argument {
  scalar64(value.reinterpret_as_uint64())
}

///|
pub fn Argument::uint64(value : UInt64) -> Argument {
  scalar64(value)
}

///|
pub fn Argument::float32(value : Float) -> Argument {
  scalar32(value.reinterpret_as_uint())
}

///|
pub fn Argument::float64(value : Double) -> Argument {
  scalar64(value.reinterpret_as_int64().reinterpret_as_uint64())
}

///|
/// Actual C++/CUDA bool is one byte, distinct from MoonBit's C FFI Bool.
pub fn Argument::boolean(value : Bool) -> Argument {
  Value(if value { b"\x01" } else { b"\x00" }, 1U, [])
}

///|
/// Shape/strides are descriptor axes and byte strides, including noncontiguous
/// positive-stride views. The native plugin constructs the actual Warp array_t
/// layout and checks the full reachable byte span against owned buffer bounds.
pub fn Argument::array(
  buffer : Buffer,
  shape : Array[Int32],
  strides : Array[Int32],
  element_size : UInt32,
  offset~ : UInt64 = 0UL,
  gradient? : Buffer,
  gradient_offset~ : UInt64 = 0UL,
) -> Argument {
  ArrayView(
    buffer,
    shape.copy(),
    strides.copy(),
    element_size,
    offset,
    gradient,
    gradient_offset,
  )
}

///|
fn buffer_index(buffers : Array[Handle], buffer : Buffer) -> UInt32 raise {
  buffer.0.checked()
  let index = buffers.length()
  buffers.push(buffer.0)
  index.reinterpret_as_uint()
}

///|
fn append_argument(
  out : Array[Byte],
  buffers : Array[Handle],
  argument : Argument,
) -> Unit raise {
  match argument {
    Value(bytes, alignment, relocations) => {
      guard bytes.length() > 0 &&
        bytes.length() <= 16777216 &&
        alignment > 0U &&
        alignment <= 256U &&
        (alignment & (alignment - 1U)) == 0U &&
        relocations.length() <= 65535 else {
        fail("invalid kernel value blob, alignment or relocation count")
      }
      append_u32(out, 0U)
      append_u32(out, alignment)
      append_u32(out, bytes.length().reinterpret_as_uint())
      for byte in bytes {
        out.push(byte)
      }
      append_u32(out, relocations.length().reinterpret_as_uint())
      for relocation in relocations {
        match relocation {
          Data(slot, buffer, offset) => {
            append_u32(out, slot)
            append_u32(out, 1U)
            append_u32(out, buffer_index(buffers, buffer))
            append_u64(out, offset)
          }
          ExternalHandle(slot, handle) => {
            append_u32(out, slot)
            append_u32(out, 2U)
            append_u32(out, 0U)
            append_u64(out, handle)
          }
          Null(slot) => {
            append_u32(out, slot)
            append_u32(out, 3U)
            append_u32(out, 0U)
            append_u64(out, 0UL)
          }
        }
      }
    }
    ArrayView(
      buffer,
      shape,
      strides,
      element,
      offset,
      gradient,
      gradient_offset
    ) => {
      guard shape.length() >= 1 &&
        shape.length() <= 4 &&
        shape.length() == strides.length() &&
        shape.all(v => v >= 0) &&
        strides.all(v => v >= 0) else {
        fail("invalid array rank, shape or nonnegative byte strides")
      }
      append_u32(out, 1U)
      append_u32(out, shape.length().reinterpret_as_uint())
      for dimension in shape {
        append_u32(out, dimension.reinterpret_as_uint())
      }
      for stride in strides {
        append_u32(out, stride.reinterpret_as_uint())
      }
      append_u32(out, element)
      append_u32(out, buffer_index(buffers, buffer))
      append_u64(out, offset)
      append_u32(
        out,
        match gradient {
          Some(value) => buffer_index(buffers, value)
          None => 4294967295U
        },
      )
      append_u64(out, gradient_offset)
    }
  }
}

///|
/// Call actual wp_cuda_launch_kernel. CUDA launches execute or enter an active
/// CUDA graph while the same call records APIC metadata when capture_state is
/// supplied. This is never a metadata-only operation or an implicit self-check.
/// Caller must retain Context through any resulting graph's entire lifetime.
pub fn Kernel::launch(
  self : Kernel,
  shape : Array[Int32],
  arguments : Array[Argument],
  adjoint_arguments~ : Array[Argument] = [],
  forward~ : Bool = true,
  max_blocks~ : Int32 = 0,
  grid_stride~ : Bool = true,
  cluster_dim~ : Int32 = 1,
  capture_state~ : UInt64 = 0UL,
) -> Unit raise {
  self.0.checked()
  guard shape.length() >= 1 &&
    shape.length() <= 4 &&
    shape.all(v => v >= 0) &&
    max_blocks >= 0 &&
    cluster_dim >= 1 &&
    cluster_dim <= 255 &&
    arguments.length() <= 65535 &&
    (
      (forward && adjoint_arguments.is_empty()) ||
      (!forward && adjoint_arguments.length() == arguments.length())
    ) else {
    fail("invalid kernel launch shape, options or adjoint argument count")
  }
  let out = []
  let buffers = []
  append_u32(out, 0x314c524dU)
  append_u32(out, shape.length().reinterpret_as_uint())
  for dimension in shape {
    append_u32(out, dimension.reinterpret_as_uint())
  }
  append_u32(out, if forward { 1U } else { 0U })
  append_u32(out, max_blocks.reinterpret_as_uint())
  append_u32(out, if grid_stride { 1U } else { 0U })
  append_u32(out, cluster_dim.reinterpret_as_uint())
  append_u32(out, arguments.length().reinterpret_as_uint())
  append_u32(out, adjoint_arguments.length().reinterpret_as_uint())
  for argument in arguments {
    append_argument(out, buffers, argument)
  }
  for argument in adjoint_arguments {
    append_argument(out, buffers, argument)
  }
  guard out.length() <= 67108864 else {
    fail("kernel argument transport exceeds 64MiB")
  }
  self.0.checked(
    status=launch_ffi(
      self.0,
      Bytes::from_array(out),
      FixedArray::makei(buffers.length(), i => buffers[i]),
      capture_state,
    ),
  )
}
