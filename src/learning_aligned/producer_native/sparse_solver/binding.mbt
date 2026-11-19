///|
fn checked_bindings(
  params : Array[Parameter],
  bindings : Array[Binding],
  shapes : Map[String, Array[Int32]],
  allow_rhs_alias : Bool,
) -> Unit raise SolverError {
  guard params.length() == bindings.length() else {
    raise Invalid("solver binding cardinality differs")
  }
  let seen : Map[String, Unit] = Map([])
  let owners : Map[String, Binding] = Map([])
  let expected : Map[String, Parameter] = Map([])
  for param in params {
    expected[param.name] = param
  }
  for binding in bindings {
    guard !seen.contains(binding.name) &&
      !binding.owner.is_empty() &&
      expected.get(binding.name) is Some(param) else {
      raise Invalid("unknown, duplicate or ownerless solver binding")
    }
    seen[binding.name] = ()
    if owners.get(binding.owner) is Some(previous) {
      let rhs_solution = (binding.name == "rhs" && previous.name == "solution") ||
        (binding.name == "solution" && previous.name == "rhs")
      guard allow_rhs_alias &&
        rhs_solution &&
        binding.dtype == previous.dtype &&
        binding.shape == previous.shape &&
        binding.byte_strides == previous.byte_strides &&
        binding.offset_bytes == previous.offset_bytes &&
        binding.capacity_bytes == previous.capacity_bytes else {
        raise Invalid(
          "solver allocations alias outside the exact supported rhs/solution in-place view",
        )
      }
    } else {
      owners[binding.owner] = binding
    }
    guard shapes.get(binding.name) is Some(shape) &&
      param.dtype == binding.dtype &&
      binding.shape == shape &&
      binding.byte_strides.length() == shape.length() else {
      raise Invalid("solver typed shape or stride cardinality differs")
    }
    let width = scalar_width(binding.dtype)
    guard binding.offset_bytes % width.to_uint64() == 0UL else {
      raise Invalid("solver offset alignment differs")
    }
    let mut bytes = width
    for step in 0..<shape.length() {
      let axis = shape.length() - 1 - step
      guard shape[axis] > 0 &&
        binding.byte_strides[axis] == bytes &&
        bytes <= 268435456 / shape[axis] else {
        raise Invalid(
          "solver requires exact positive contiguous rows and bounded owner footprint",
        )
      }
      bytes *= shape[axis]
    }
    guard binding.offset_bytes <= binding.capacity_bytes &&
      bytes.to_uint64() <= binding.capacity_bytes - binding.offset_bytes else {
      raise Invalid("solver view exceeds actual owned storage")
    }
  }
}

///|
pub fn validate_bindings(
  request : Request,
  key : String,
  bindings : Array[Binding],
) -> Unit raise {
  let lowered = lower(request)
  let entries : Map[String, Entry] = Map([])
  for entry in lowered.entries {
    entries[entry.key] = entry
  }
  guard entries.get(key) is Some(entry) else {
    raise Invalid("unknown mixed solver callable")
  }
  let shapes : Map[String, Array[Int32]] = Map([])
  for item in lowered.metadata {
    shapes[item.name] = item.shape
  }
  shapes["matrix"] = [request.nworld, lowered.nC]
  if lowered.factor_width > 0 {
    shapes["factor"] = [request.nworld, lowered.factor_width]
  }
  for name in ["diagonal", "rhs", "solution"] {
    shapes[name] = [request.nworld, lowered.nv]
  }
  shapes["failure"] = [request.nworld]
  shapes["done"] = [request.nworld]
  checked_bindings(entry.parameters, bindings, shapes, true)
}

///|
fn checked_metadata(
  expected : Array[Metadata],
  actual : Array[MetadataInput],
) -> Unit raise SolverError {
  guard expected.length() == actual.length() else {
    raise Invalid("solver immutable metadata cardinality differs")
  }
  let names : Map[String, Metadata] = Map([])
  let seen : Map[String, Unit] = Map([])
  for item in expected {
    names[item.name] = item
  }
  for item in actual {
    guard !seen.contains(item.name) &&
      names.get(item.name) is Some(reference) &&
      reference.bytes == item.bytes else {
      raise Invalid(
        "actual GPU metadata bytes differ from the validated model layout: " +
        item.name,
      )
    }
    seen[item.name] = ()
  }
}

///|
/// Exact initial bytes of ALL metadata views; freeze these owners for the whole
/// graph, including inside a Newton/CG while body. No GPU/D2H read is done here.
pub fn validate_metadata(
  request : Request,
  key : String,
  actual : Array[MetadataInput],
) -> Unit raise {
  let lowered = lower(request)
  guard lowered.entries.any(entry => entry.key == key) else {
    raise Invalid("unknown mixed solver callable")
  }
  checked_metadata(lowered.metadata, actual)
}

///|
/// Check once at capture/program initialization. No body kernel clears this
/// owner: the first failure remains sticky across every later invocation.
pub fn validate_initial_failure(
  nworld : Int32,
  bytes : Bytes,
) -> Unit raise SolverError {
  guard nworld > 0 &&
    nworld <= 268435456 / 4 &&
    bytes.length() == nworld * 4 &&
    bytes.iter().all(byte => byte == 0) else {
    raise Invalid(
      "solver requires an exact initial-zero sticky int32[world] failure owner",
    )
  }
}
