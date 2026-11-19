///|
fn add_buffer(
  buffers : Map[String, HostBuffer],
  buffer : HostBuffer,
  total : Ref[Int32],
) -> Unit raise {
  let width = scalar_width(buffer.scalar_type)
  guard identifier(buffer.name) &&
    !buffers.contains(buffer.name) &&
    !buffer.bytes.is_empty() &&
    buffer.bytes.length() <= 268435456 &&
    total.val <= 536870912 - buffer.bytes.length() &&
    buffer.bytes.length() % width == 0 else {
    fail(
      "invalid/duplicate GPU buffer, scalar alignment or 512 MiB total capacity",
    )
  }
  if buffer.scalar_type == "bool" {
    guard buffer.bytes.iter().all(byte => byte == 0 || byte == 1) else {
      fail("noncanonical C++ bool bytes")
    }
  }
  total.val += buffer.bytes.length()
  buffers[buffer.name] = buffer
}

///|
async fn read_buffers(config : Config) -> Map[String, HostBuffer] {
  let result : Map[String, HostBuffer] = {}
  let total = Ref(0)
  for input in config.buffers {
    guard @contracts.sha256_hex(input.sha256) else {
      fail("GPU raw buffer requires exact SHA256")
    }
    let bytes = @fs.read_file(@fs.realpath(input.path)).binary()
    guard @artifacts.sha256(bytes) == input.sha256 else {
      fail("GPU raw buffer SHA differs")
    }
    add_buffer(
      result,
      { name: input.name, scalar_type: input.scalar_type, bytes, },
      total,
    )
  }
  for input in config.host_imports {
    guard identifier(input.prefix) &&
      @contracts.sha256_hex(input.manifest_sha256) else {
      fail("invalid finalized host import identity")
    }
    let root = @fs.realpath(input.directory)
    let bytes = @fs.read_file(root + "/layout.json").binary()
    guard @artifacts.sha256(bytes) == input.manifest_sha256 else {
      fail("finalized host layout SHA differs")
    }
    let json = @json.parse(@utf8.decode(bytes))
    guard (
        text(json, "format") == "moonrobo.rigid-tree-host-artifact.v1" ||
        text(json, "format") == "moonrobo.primitive-collision-host-artifact.v1"
      ) &&
      field(json, "files") is Array(files) else {
      fail("expected actual rigid-tree/collision finalizer artifact")
    }
    for file in files {
      let path = text(file, "path")
      let name = text(file, "name")
      guard @contracts.relative_path(path) && identifier(name) else {
        fail("unsafe finalized raw array path/name")
      }
      let metadata = field(file, "array")
      guard text(metadata, "byte_order") == "little" else {
        fail("finalizer raw array must retain declared little endian ABI")
      }
      let raw = @fs.read_file(root + "/" + path).binary()
      let count : Int32 = @json.from_json(field(metadata, "byte_length"))
      guard raw.length() == count &&
        @artifacts.sha256(raw) == text(metadata, "sha256") else {
        fail("actual finalized array byte identity differs")
      }
      let scalar_type = host_scalar_type(text(metadata, "scalar_type"))
      let shape : Array[Int32] = @json.from_json(field(metadata, "shape"))
      let components : Int32 = @json.from_json(field(metadata, "components"))
      guard shape.length() > 0 &&
        shape.length() <= 4 &&
        components > 0 &&
        components <= 16 else {
        fail("invalid finalized shape/components")
      }
      let mut expected = components * scalar_width(scalar_type)
      for extent in shape {
        guard extent >= 0 && (extent == 0 || expected <= 2147483647 / extent) else {
          fail("finalized shape byte product overflow")
        }
        expected *= extent
      }
      guard expected == count else {
        fail("finalized shape/components disagree with actual raw bytes")
      }
      // Empty physical arrays have metadata but no CUDA allocation. Alias
      // entries live in layout.aliases and never create duplicate owners.
      if count > 0 {
        add_buffer(
          result,
          { name: input.prefix + "." + name, scalar_type, bytes: raw, },
          total,
        )
      }
    }
  }
  result
}

///|
/// Complete reachable byte span, retaining arbitrary positive-stride inputs.
fn span(
  view : View,
  buffers : Map[String, HostBuffer],
) -> (UInt64, UInt64) raise {
  guard buffers.get(view.buffer) is Some(owner) else {
    fail("unknown owned GPU buffer: " + view.buffer)
  }
  let (scalar, width) = element(view.dtype)
  let alignment = scalar_width(scalar)
  guard owner.scalar_type == scalar &&
    view.shape.length() > 0 &&
    view.shape.length() <= 4 &&
    view.shape.length() == view.byte_strides.length() &&
    view.shape.all(n => n >= 0) &&
    view.byte_strides.all(n => n > 0 && n % alignment == 0) &&
    view.offset_bytes % alignment.to_uint64() == 0UL &&
    view.offset_bytes <= owner.bytes.length().to_uint64() else {
    fail("GPU array dtype/rank/shape/strides/alignment/offset is invalid")
  }
  // A logical empty array still has an explicitly owned ABI pointer, but its
  // reachable interval is empty. This supports genuine zero-DOF/zero-row paths
  // without inventing data elements or launching a zero-dimensional grid.
  if view.shape.any(n => n == 0) {
    return (view.offset_bytes, view.offset_bytes)
  }
  guard owner.bytes.length() >= width &&
    view.offset_bytes <= (owner.bytes.length() - width).to_uint64() else {
    fail("GPU array dtype/rank/shape/strides/alignment/offset is invalid")
  }
  let mut remaining = (owner.bytes.length() - width).to_uint64() -
    view.offset_bytes
  let mut end = view.offset_bytes + width.to_uint64()
  for axis in 0..<view.shape.length() {
    let count = (view.shape[axis] - 1).to_uint64()
    let stride = view.byte_strides[axis].to_uint64()
    guard count <= remaining / stride else {
      fail("GPU view full reachable span exceeds owned allocation")
    }
    let bytes = count * stride
    remaining -= bytes
    end += bytes
  }
  (view.offset_bytes, end)
}

///|
fn writable(view : View) -> Unit raise {
  if view.shape.any(n => n == 0) {
    return
  }
  let (_, width) = element(view.dtype)
  let order = Array::makei(view.shape.length(), i => i)
  order.sort_by(fn(a, b) { view.byte_strides[a].compare(view.byte_strides[b]) })
  let mut covered = width.to_uint64()
  for axis in order {
    if view.shape[axis] > 1 {
      let stride = view.byte_strides[axis].to_uint64()
      guard stride >= covered else {
        fail("GPU writable view aliases its own elements")
      }
      covered += (view.shape[axis] - 1).to_uint64() * stride
    }
  }
}

///|
fn strict_view(value : Json) -> View raise {
  ignore(
    fields(value, ["buffer", "dtype", "shape", "byte_strides", "offset_bytes"]),
  )
  @json.from_json(value)
}

///|
fn scalar_i32(
  view : View,
  buffers : Map[String, HostBuffer],
  indices : Array[Int32],
) -> Int32 raise {
  guard view.dtype == "int32" && indices.length() == view.shape.length() else {
    fail("typed index read requires int32 with matching rank")
  }
  let bytes = buffers[view.buffer].bytes
  let mut offset = view.offset_bytes.to_int()
  for axis, index in indices {
    guard index >= 0 && index < view.shape[axis] else {
      fail("typed index metadata read outside view shape")
    }
    offset += index * view.byte_strides[axis]
  }
  let bits = bytes[offset].to_uint() |
    (bytes[offset + 1].to_uint() << 8) |
    (bytes[offset + 2].to_uint() << 16) |
    (bytes[offset + 3].to_uint() << 24)
  bits.reinterpret_as_int()
}

///|
fn memory_range(
  buffer : String,
  offset : UInt64,
  count : UInt64,
  buffers : Map[String, HostBuffer],
) -> Unit raise {
  guard buffers.get(buffer) is Some(owner) &&
    offset <= owner.bytes.length().to_uint64() &&
    count <= owner.bytes.length().to_uint64() - offset else {
    fail("GPU memory operation exceeds owned storage")
  }
}

///|
/// Canonical little-endian snapshot of the actual view, including every
/// component of compound elements. Used only for source metadata/index proofs;
/// this neither converts scalars nor evaluates any numerical solver.
fn packed_view(view : View, buffers : Map[String, HostBuffer]) -> Bytes raise {
  ignore(span(view, buffers))
  if view.shape.any(n => n == 0) {
    return b""
  }
  let (_, width) = element(view.dtype)
  let mut count = 1
  for extent in view.shape {
    guard count <= 268435456 / width / extent else {
      fail("canonical metadata snapshot exceeds the owned-buffer size bound")
    }
    count *= extent
  }
  let source = buffers[view.buffer].bytes
  Bytes::makei(count * width, byte => {
    let linear = byte / width
    let mut remainder = linear
    let mut offset = view.offset_bytes.to_int()
    for step in 0..<view.shape.length() {
      let axis = view.shape.length() - 1 - step
      let index = remainder % view.shape[axis]
      remainder /= view.shape[axis]
      offset += index * view.byte_strides[axis]
    }
    source[offset + byte % width]
  })
}
