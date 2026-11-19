///|
/// Derived exclusively from actual live owned Buffer/View metadata.
pub(all) struct Binding {
  name : String
  allocation : String
  dtype : String
  shape : Array[Int32]
  byte_strides : Array[Int32]
  byte_offset : Int64
  buffer_bytes : Int64
} derive(FromJson, ToJson, Debug)

///|
fn element_bytes(dtype : String) -> Int64 raise {
  match dtype {
    "int32" | "float32" => 4L
    "vec2i" | "vec2f" => 8L
    "vec3f" => 12L
    "vec4f" => 16L
    "vec5f" => 20L
    "mat33f" => 36L
    _ => raise Unsupported::Invalid("unsupported native contact dtype")
  }
}

///|
fn extent(binding : Binding, param : Parameter) -> (Int64, Int64) raise {
  guard !binding.allocation.is_empty() &&
    binding.dtype == param.dtype &&
    binding.shape.length() == param.rank &&
    binding.byte_strides.length() == param.rank &&
    binding.shape.all(n => n >= 0) &&
    binding.byte_strides.all(n => n >= 0 && n % 4 == 0) &&
    binding.byte_offset >= 0 &&
    binding.byte_offset % 4 == 0 &&
    binding.buffer_bytes >= binding.byte_offset else {
    raise Unsupported::Invalid(
      "invalid owned contact view metadata: " + param.name,
    )
  }
  if binding.shape.any(n => n == 0) {
    return (binding.byte_offset, binding.byte_offset)
  }
  let width = element_bytes(param.dtype)
  guard width <= binding.buffer_bytes - binding.byte_offset else {
    raise Unsupported::Invalid("native contact element exceeds owner")
  }
  let mut end = binding.byte_offset + width
  for axis in 0..<param.rank {
    let count = (binding.shape[axis] - 1).to_int64()
    let stride = binding.byte_strides[axis].to_int64()
    guard count == 0 || stride <= (binding.buffer_bytes - end) / count else {
      raise Unsupported::Invalid(
        "native contact stride footprint exceeds owner",
      )
    }
    end += count * stride
  }
  if param.access != "input" {
    let order = if param.rank == 2 &&
      binding.byte_strides[0] > binding.byte_strides[1] {
      [1, 0]
    } else {
      Array::makei(param.rank, i => i)
    }
    let mut span = width
    for axis in order {
      if binding.shape[axis] > 1 {
        let stride = binding.byte_strides[axis].to_int64()
        guard stride >= span else {
          raise Unsupported::Invalid(
            "writable contact/scratch elements overlap",
          )
        }
        span += (binding.shape[axis] - 1).to_int64() * stride
      }
    }
  }
  (binding.byte_offset, end)
}

///|
/// Mandatory host proof for all 69 descriptors. It checks actual reachable
/// bytes, not alleged element counts; all scratch/output footprints are disjoint.
pub fn validate_bindings(
  request : Request,
  bindings : Array[Binding],
) -> Unit raise {
  validate_request(request)
  let params = parameters()
  guard bindings.length() == params.length() else {
    raise Unsupported::Invalid("exactly 69 native contact bindings required")
  }
  let indexed : Map[String, Binding] = {}
  for binding in bindings {
    guard !indexed.contains(binding.name) else {
      raise Unsupported::Invalid("duplicate native contact binding")
    }
    indexed[binding.name] = binding
  }
  let intervals : Array[(String, Int64, Int64, Bool)] = []
  for param in params {
    guard indexed.get(param.name) is Some(b) else {
      raise Unsupported::Invalid("missing contact binding: " + param.name)
    }
    let (start, end) = extent(b, param)
    let shape = b.shape
    let name = param.name
    if name.has_prefix("geom_") {
      if param.rank == 1 {
        guard shape[0] >= request.ngeom else {
          raise Unsupported::Invalid("geom vector capacity differs")
        }
      } else {
        let worlds = if name == "geom_xpos_in" || name == "geom_xmat_in" {
          request.nworld
        } else {
          1
        }
        guard shape[0] >= worlds && shape[1] >= request.ngeom else {
          raise Unsupported::Invalid("geom batch capacity differs")
        }
      }
    } else if name.has_prefix("pair_") && param.rank == 2 {
      let count = indexed["pair_dim"].shape[0]
      guard shape[1] >= count && (count == 0 || shape[0] > 0) else {
        raise Unsupported::Invalid("pair batch capacity differs")
      }
    } else if name.has_prefix("collision_") {
      guard shape[0] >= request.candidate_capacity else {
        raise Unsupported::Invalid("candidate capacity differs")
      }
    } else if name.has_prefix("contact_") {
      guard shape[0] >= request.contact_capacity else {
        raise Unsupported::Invalid("contact capacity differs")
      }
      if param.rank == 2 {
        guard shape[1] == request.efc_slots else {
          raise Unsupported::Invalid("contact EFC slot count differs")
        }
      }
    } else if name.has_prefix("epa_") {
      let columns = scratch_columns(request, name)
      guard shape == [request.candidate_capacity, columns] else {
        raise Unsupported::Invalid("EPA scratch shape differs")
      }
    } else if name == "nacon_out" || name == "ncollision_in" {
      guard shape[0] >= 1 else {
        raise Unsupported::Invalid("counter storage missing")
      }
    } else if name == "rejected_out" {
      guard shape == [8] && b.byte_strides == [4] else {
        raise Unsupported::Invalid(
          "eight contiguous rejection counters required",
        )
      }
    } else if name.has_prefix("hfield_") {
      let count = if name == "hfield_data" {
        request.hfield_data_capacity
      } else {
        request.hfield_capacity
      }
      guard shape[0] >= count else {
        raise Unsupported::Invalid("heightfield resource capacity differs")
      }
    } else if name.has_prefix("mesh_") {
      let count = if name == "mesh_vertex" {
        request.vertex_capacity
      } else if name == "mesh_polyvert" {
        request.polygon_vertex_capacity
      } else if name == "mesh_polymap" {
        request.polygon_map_capacity
      } else if name == "mesh_graph" {
        request.graph_capacity
      } else if name == "mesh_polymapadr" || name == "mesh_polymapnum" {
        request.vertex_capacity
      } else {
        request.polygon_capacity
      }
      guard shape[0] >= count else {
        raise Unsupported::Invalid("mesh topology capacity differs")
      }
    }
    let writable = param.access != "input"
    if start != end {
      for (allocation, lo, hi, other_write) in intervals {
        guard allocation != b.allocation ||
          !(writable || other_write) ||
          end <= lo ||
          start >= hi else {
          raise Unsupported::Invalid(
            "native contact writable/scratch views overlap another binding",
          )
        }
      }
      intervals.push((b.allocation, start, end, writable))
    }
  }
}
