///|
pub(all) enum ScanType {
  I32
  I64
  F32
  F64
} derive(Eq)

///|
pub extend ScanType with Eq::{equal, not_equal}

///|
pub fn ScanType::byte_width(self : ScanType) -> Int32 {
  match self {
    I32 | F32 => 4
    I64 | F64 => 8
  }
}

///|
fn ScanType::code(self : ScanType) -> Int32 {
  match self {
    I32 => 1
    I64 => 2
    F32 => 3
    F64 => 4
  }
}

///|
/// A declared typed view retains its native Buffer owner. Creating one checks
/// its complete reachable storage span; it never reads or guesses GPU values.
pub struct TypedView {
  buffer : Buffer
  scalar_type : ScanType
  count : Int32
  offset : UInt64
  stride : Int32
  components : Int32
}

///|
/// Immutable validated host partition, uploaded before capture. No writable
/// Buffer/pointer is exposed; the native owner retains the exact host bytes.
pub struct SegmentPartition {
  handle : Handle
  count : Int32
  num_segments : Int32
}

///|
fn partition_bytes(boundaries : Array[Int32], count : Int32) -> Bytes raise {
  guard count >= 0 &&
    boundaries.length() >= 1 &&
    boundaries.length() <= 1048577 &&
    boundaries[0] == 0 &&
    boundaries[boundaries.length() - 1] == count &&
    (count == 0 || boundaries.length() >= 2) else {
    fail(
      "partition must start at zero, end at count, and fit the supported size",
    )
  }
  let out = []
  let mut previous = 0
  for boundary in boundaries {
    guard boundary >= previous && boundary <= count else {
      fail("partition boundaries must be monotone and lie in [0,count]")
    }
    append_u32(out, boundary.reinterpret_as_uint())
    previous = boundary
  }
  Bytes::from_array(out)
}

///|
#borrow(context, values)
extern "c" fn partition_ffi(
  context : Handle,
  values : Bytes,
  count : Int32,
) -> Handle = "moonrobo_dispatch_partition"

///|
/// Validates actual boundary values, then allocates and uploads immutable
/// int32 storage outside capture. Supports empty/repeated segments.
pub fn Context::segment_partition(
  self : Context,
  boundaries : Array[Int32],
  count : Int32,
) -> SegmentPartition raise {
  self.0.checked()
  let bytes = partition_bytes(boundaries, count)
  let handle = partition_ffi(self.0, bytes, count)
  handle.checked()
  { handle, count, num_segments: boundaries.length() - 1, }
}

///|
pub fn SegmentPartition::count(self : SegmentPartition) -> Int32 {
  self.count
}

///|
pub fn SegmentPartition::num_segments(self : SegmentPartition) -> Int32 {
  self.num_segments
}

///|
pub fn SegmentPartition::close(self : SegmentPartition) -> Unit {
  close_ffi(self.handle)
}

///|
fn typed_span(
  scalar_type : ScanType,
  count : Int32,
  stride : Int32,
  components : Int32,
) -> UInt64 raise {
  let width = scalar_type.byte_width()
  guard count >= 0 &&
    components > 0 &&
    components <= 2147483647 / width &&
    stride >= components * width &&
    stride % width == 0 else {
    fail("invalid typed view count, stride or component count")
  }
  if count == 0 {
    0UL
  } else {
    (count - 1).to_uint64() * stride.to_uint64() +
    components.to_uint64() * width.to_uint64()
  }
}

///|
pub fn Buffer::typed_view(
  self : Buffer,
  scalar_type : ScanType,
  count : Int32,
  offset~ : UInt64 = 0UL,
  stride? : Int32,
  components~ : Int32 = 1,
) -> TypedView raise {
  let width = scalar_type.byte_width()
  guard components > 0 && components <= 2147483647 / width else {
    fail("typed component count overflows")
  }
  let stride = stride.unwrap_or(components * width)
  let span = typed_span(scalar_type, count, stride, components)
  let size = self.size()
  guard offset % width.to_uint64() == 0UL &&
    offset <= size &&
    span <= size - offset else {
    fail("typed view lies outside owned buffer or is misaligned")
  }
  { buffer: self, scalar_type, count, offset, stride, components, }
}

///|
pub fn TypedView::count(self : TypedView) -> Int32 {
  self.count
}

///|
pub fn TypedView::scalar_type(self : TypedView) -> ScanType {
  self.scalar_type
}

///|
#borrow(context, input, output)
extern "c" fn scan_ffi(
  context : Handle,
  input : Handle,
  output : Handle,
  in_offset : UInt64,
  out_offset : UInt64,
  scalar_type : Int32,
  count : Int32,
  in_stride : Int32,
  out_stride : Int32,
  components : Int32,
  inclusive : Int32,
  state : UInt64,
) -> Int32 = "moonrobo_dispatch_scan"

///|
#borrow(context, keys, values, partition)
extern "c" fn segmented_sort_ffi(
  context : Handle,
  keys : Handle,
  values : Handle,
  partition : Handle,
  key_offset : UInt64,
  value_offset : UInt64,
  scalar_type : Int32,
  state : UInt64,
) -> Int32 = "moonrobo_dispatch_segmented_sort"

///|
/// Real APIC-aware Warp/CUB inclusive or exclusive component-wise sum.
/// Both typed views must have equal scalar type, length and component count.
pub fn Context::scan(
  self : Context,
  input : TypedView,
  output : TypedView,
  inclusive~ : Bool = true,
  capture_state~ : UInt64 = 0UL,
) -> Unit raise {
  self.0.checked()
  guard input.scalar_type == output.scalar_type &&
    input.count == output.count &&
    input.components == output.components else {
    fail("scan input/output typed layouts differ")
  }
  input.buffer.0.checked()
  output.buffer.0.checked()
  self.0.checked(
    status=scan_ffi(
      self.0,
      input.buffer.0,
      output.buffer.0,
      input.offset,
      output.offset,
      input.scalar_type.code(),
      input.count,
      input.stride,
      output.stride,
      input.components,
      if inclusive {
        1
      } else {
        0
      },
      capture_state,
    ),
  )
}

///|
/// Real Warp/CUB segmented pair sort. Keys (I32/F32) and values (I32) each
/// provide 2*count contiguous elements, preserving CUB double-buffer scratch.
/// Boundaries come only from an immutable, actually validated SegmentPartition;
/// arbitrary mutable GPU boundary views are deliberately unsupported.
pub fn Context::segmented_sort_pairs(
  self : Context,
  keys : TypedView,
  values : TypedView,
  partition : SegmentPartition,
  capture_state~ : UInt64 = 0UL,
) -> Unit raise {
  self.0.checked()
  let count = partition.count
  guard (keys.scalar_type == I32 || keys.scalar_type == F32) &&
    values.scalar_type == I32 &&
    keys.components == 1 &&
    values.components == 1 &&
    keys.stride == 4 &&
    values.stride == 4 &&
    keys.count.to_int64() >= count.to_int64() * 2L &&
    values.count.to_int64() >= count.to_int64() * 2L else {
    fail("segmented sort requires typed contiguous 2*count key/value buffers")
  }
  keys.buffer.0.checked()
  values.buffer.0.checked()
  partition.handle.checked()
  self.0.checked(
    status=segmented_sort_ffi(
      self.0,
      keys.buffer.0,
      values.buffer.0,
      partition.handle,
      keys.offset,
      values.offset,
      keys.scalar_type.code(),
      capture_state,
    ),
  )
}
