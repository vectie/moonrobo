///|
/// Metadata must be constructed from the actual owned native Buffer/View, not
/// guessed from element counts. allocation identifies the live backing Buffer.
pub(all) struct Binding {
  name : String
  allocation : String
  dtype : String
  shape : Array[Int32]
  byte_strides : Array[Int32]
  byte_offset : Int64
  buffer_bytes : Int64
} derive(Debug, FromJson, ToJson)

///|
fn element_bytes(dtype : String) -> Int64 raise {
  match dtype {
    "int32" | "float32" => 4L
    "vec2i" | "vec2f" => 8L
    "vec3f" => 12L
    "vec5f" => 20L
    "mat33f" => 36L
    _ => raise Unsupported::Invalid("unsupported binding dtype")
  }
}

///|
fn extent(binding : Binding, param : Parameter) -> (Int64, Int64) raise {
  guard binding.allocation != "" &&
    binding.dtype == param.dtype &&
    binding.shape.length() == param.rank &&
    binding.byte_strides.length() == param.rank &&
    binding.shape.all(n => n >= 0) &&
    binding.byte_strides.all(n => n >= 0 && n % 4 == 0) &&
    binding.byte_offset >= 0 &&
    binding.byte_offset % 4 == 0 &&
    binding.buffer_bytes >= binding.byte_offset else {
    raise Unsupported::Invalid("invalid native view metadata for " + param.name)
  }
  if binding.shape.any(n => n == 0) {
    return (binding.byte_offset, binding.byte_offset)
  }
  let size = element_bytes(param.dtype)
  guard size <= binding.buffer_bytes - binding.byte_offset else {
    raise Unsupported::Invalid("native view exceeds backing Buffer")
  }
  let mut end = binding.byte_offset + size
  for axis in 0..<param.rank {
    let term = (binding.shape[axis] - 1).to_int64() *
      binding.byte_strides[axis].to_int64()
    guard term <= binding.buffer_bytes - end else {
      raise Unsupported::Invalid(
        "native view stride footprint exceeds backing Buffer",
      )
    }
    end += term
  }
  if param.access != "input" {
    let order = if param.rank == 2 &&
      binding.byte_strides[0] > binding.byte_strides[1] {
      [1, 0]
    } else {
      Array::makei(param.rank, i => i)
    }
    let mut span = size
    for axis in order {
      if binding.shape[axis] > 1 {
        let stride = binding.byte_strides[axis].to_int64()
        guard stride >= span else {
          raise Unsupported::Invalid(
            "writable native view internally aliases its elements",
          )
        }
        span += (binding.shape[axis] - 1).to_int64() * stride
      }
    }
  }
  (binding.byte_offset, end)
}

///|
/// Mandatory before constructing native Arguments for this module. Checks all
/// 42 typed views, real backing allocation extents and conservative disjointness
/// of every writable view. It performs no allocation, kernel or numeric work.
pub fn validate_bindings(
  request : Request,
  bindings : Array[Binding],
) -> Unit raise {
  let plan = lower(request)
  let indexed : Map[String, Binding] = {}
  guard bindings.length() == plan.entry.parameters.length() else {
    raise Unsupported::Invalid("exactly 42 native bindings required")
  }
  for binding in bindings {
    guard !indexed.contains(binding.name) else {
      raise Unsupported::Invalid("duplicate native binding")
    }
    indexed[binding.name] = binding
  }
  let intervals : Array[(String, Int64, Int64, Bool)] = []
  for param in plan.entry.parameters {
    guard indexed.get(param.name) is Some(b) else {
      raise Unsupported::Invalid("missing native binding: " + param.name)
    }
    let (start, end) = extent(b, param)
    let shape = b.shape
    let name = b.name
    if name.has_prefix("geom_") {
      if param.rank == 1 {
        guard shape[0] >= request.ngeom else {
          raise Unsupported::Invalid("geom vector does not cover every geom")
        }
      } else {
        let worlds = if name == "geom_xpos_in" || name == "geom_xmat_in" {
          request.nworld
        } else {
          1
        }
        guard shape[0] >= worlds && shape[1] >= request.ngeom else {
          raise Unsupported::Invalid("geom matrix/batch shape differs")
        }
      }
    } else if name.has_prefix("pair_") && param.rank == 2 {
      let pair_count = indexed["pair_dim"].shape[0]
      guard shape[1] >= pair_count && (pair_count == 0 || shape[0] > 0) else {
        raise Unsupported::Invalid("explicit-pair material batch shape differs")
      }
    } else if name.has_prefix("collision_") {
      guard shape[0] >= request.candidate_capacity else {
        raise Unsupported::Invalid("candidate view capacity differs")
      }
    } else if name.has_prefix("contact_") {
      guard shape[0] >= request.contact_capacity else {
        raise Unsupported::Invalid("contact output view capacity differs")
      }
      if param.rank == 2 {
        guard shape[1] == request.efc_slots else {
          raise Unsupported::Invalid("contact EFC slot count differs")
        }
      }
    } else if name == "nacon_out" || name == "ncollision_in" {
      guard shape[0] >= 1 else {
        raise Unsupported::Invalid("counter storage missing")
      }
    } else if name == "rejected_out" {
      guard shape == [2] && b.byte_strides == [4] else {
        raise Unsupported::Invalid("two contiguous rejection counters required")
      }
    }
    let writable = param.access != "input"
    if start != end {
      for (allocation, lo, hi, other_writable) in intervals {
        guard allocation != b.allocation ||
          !(writable || other_writable) ||
          end <= lo ||
          start >= hi else {
          raise Unsupported::Invalid("writable native views must not overlap")
        }
      }
      intervals.push((b.allocation, start, end, writable))
    }
  }
}
