///|
/// Raw initial bytes are explicit inputs, including the initial contents of
/// output/inout buffers. Multiple array arguments can reference the same owner.
pub(all) struct BufferInput {
  name : String
  path : String
  sha256 : String
  scalar_type : String
} derive(FromJson, ToJson, Debug)

///|
/// Array argument JSON is a named buffer with exact shape, positive physical
/// byte strides and byte offset. Scalar arguments are JSON int32 or bool.
pub(all) struct ArrayInput {
  buffer : String
  shape : Array[Int32]
  byte_strides : Array[Int32]
  offset_bytes : UInt64
} derive(FromJson, ToJson, Debug)

///|
/// Explicit offline kernel capture; calling capture creates a CUDA context and
/// records a real kernel. It is never a metadata-only command or a probe.
pub(all) struct CaptureConfig {
  dispatch_plugin : String
  writer_plugin : String
  warp_library : String
  device_ordinal : Int32
  architecture : Int32
  compiled_directory : String
  compiled_manifest_sha256 : String
  kernel_key : String
  buffers : Array[BufferInput]
  arguments : Map[String, Json]
  output : String
} derive(FromJson, ToJson, Debug)

///|
struct LoadedBuffer {
  input : BufferInput
  bytes : Bytes
  scalar_bytes : Int32
}

///|
enum TypedArgument {
  Array(ArrayInput, Int32)
  Integer(Int32)
  Boolean(Bool)
}

///|
struct Prepared {
  entry : @kernels.Entry
  specialization : @kernels.Specialization
  manifest : Json
  manifest_bytes : Bytes
  notice : Bytes
  image : Bytes
  image_path : String
  image_kind : String
  image_sha256 : String
  buffers : Array[LoadedBuffer]
  arguments : Array[TypedArgument]
  dispatch_plugin : String
  writer_plugin : String
  warp_library : String
}

///|
fn json_field(value : Json, key : String) -> Json raise {
  guard value is Object(fields) && fields.get(key) is Some(item) else {
    fail("kernel capture: missing field " + key)
  }
  item
}

///|
fn text(value : Json, key : String) -> String raise {
  @json.from_json(json_field(value, key))
}

///|
fn scalar_bytes(dtype : String) -> Int32 raise {
  match dtype {
    "float32" | "int32" => 4
    "bool" => 1
    _ =>
      fail("kernel capture supports primitive float32/int32/bool owned buffers")
  }
}

///|
fn element(dtype : String) -> (String, Int32) raise {
  match dtype {
    "float32" => ("float32", 4)
    "int32" => ("int32", 4)
    "bool" => ("bool", 1)
    "transformf" => ("float32", 28)
    "spatial_vectorf" => ("float32", 24)
    _ => fail("kernel capture: unsupported concrete parameter dtype")
  }
}

///|
/// Prove the exact final reachable element fits before adding/multiplying.
fn validate_array(
  value : ArrayInput,
  rank : Int32,
  width : Int32,
  alignment : Int32,
  capacity : Int32,
) -> Unit raise {
  guard rank > 0 &&
    rank <= 4 &&
    value.shape.length() == rank &&
    value.byte_strides.length() == rank &&
    value.shape.all(n => n > 0) &&
    value.byte_strides.all(n => n > 0 && n % alignment == 0) &&
    value.offset_bytes % alignment.to_uint64() == 0UL &&
    capacity >= width &&
    value.offset_bytes <= (capacity - width).to_uint64() else {
    fail("kernel capture: invalid array rank/shape/byte strides/offset")
  }
  let mut remaining = (capacity - width).to_int64() -
    value.offset_bytes.to_int64()
  for axis in 0..<rank {
    let count = (value.shape[axis] - 1).to_int64()
    let stride = value.byte_strides[axis].to_int64()
    guard count <= remaining / stride else {
      fail("kernel capture: array reaches outside owned raw buffer")
    }
    remaining -= count * stride
  }
}

///|
fn expected_shape(
  entry : @kernels.Entry,
  parameter : @kernels.Parameter,
  request : @kernels.SpecializationRequest,
) -> Array[Int32] raise {
  let bodies = entry.key == "publish-body-state" ||
    entry.key == "publish-body-pose" ||
    entry.key == "publish-body-velocity"
  if parameter.rank == 2 {
    [
      request.num_envs,
      if bodies || parameter.name == "body_acc_w" {
        request.num_bodies
      } else {
        request.num_joints
      },
    ]
  } else if parameter.rank == 1 {
    [
      if parameter.name == "env_mask" {
        request.num_envs
      } else if parameter.name == "user_mask" ||
        parameter.name == "joint_mask" ||
        parameter.name == "joint_modes" ||
        parameter.name == "joint_indices" ||
        parameter.name == "backend_to_user" {
        request.num_joints
      } else if parameter.name == "user_to_backend" ||
        parameter.name == "dst_to_src" {
        if bodies {
          request.num_bodies
        } else {
          request.num_joints
        }
      } else {
        request.num_envs
      },
    ]
  } else {
    fail("kernel capture: concrete array rank unsupported")
  }
}

///|
/// CUDA threads must never write overlapping compound elements or rows.
fn validate_writable(array : ArrayInput, width : Int32) -> Unit raise {
  if array.shape.length() == 1 {
    guard array.byte_strides[0] >= width else {
      fail("kernel capture: writable compound elements overlap")
    }
  } else {
    guard array.shape.length() == 2 &&
      array.byte_strides[1] >= width &&
      array.byte_strides[0].to_int64() >=
      (array.shape[1] - 1).to_int64() * array.byte_strides[1].to_int64() +
      width.to_int64() else {
      fail("kernel capture: writable array rows/elements overlap")
    }
  }
}

///|
/// Gather/scatter maps are actual signed int32 bytes, not trusted extents.
fn validate_index_data(
  array : ArrayInput,
  bytes : Bytes,
  limit : Int32,
) -> Unit raise {
  let start = array.offset_bytes.to_int()
  let seen : Array[Int32] = []
  for i in 0..<array.shape[0] {
    let offset = start + i * array.byte_strides[0]
    let bits = bytes[offset].to_uint() |
      (bytes[offset + 1].to_uint() << 8) |
      (bytes[offset + 2].to_uint() << 16) |
      (bytes[offset + 3].to_uint() << 24)
    let value = bits.reinterpret_as_int()
    guard value >= 0 && value < limit && !seen.contains(value) else {
      fail(
        "kernel capture: fixed gather/scatter map is not a bounded permutation",
      )
    }
    seen.push(value)
  }
}
