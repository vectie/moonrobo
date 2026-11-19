///|
fn width(dtype : String) -> Int32 raise TileError {
  match dtype {
    "float32" => 4
    "float64" => 8
    _ => raise Invalid("MathDx tile supports float32/float64 only")
  }
}

///|
fn validate(request : Request) -> Int32 raise TileError {
  guard request.operation == "factor" || request.operation == "factor-solve" else {
    raise Invalid(
      "operation must be factor or factor-solve; untrusted-factor solve is not supplied",
    )
  }
  guard request.tile_size > 0 &&
    request.tile_size <= 64 &&
    request.rhs_columns > 0 &&
    request.rhs_columns <= 64 &&
    (request.operation == "factor-solve" || request.rhs_columns == 1) &&
    request.batch_size > 0 &&
    [32, 64, 128, 256].contains(request.block_dim) &&
    request.batch_size <= 2147483647 / request.block_dim &&
    [80, 86, 87, 89, 90, 100, 103, 110, 120, 121].contains(request.architecture) else {
    raise Invalid(
      "unsupported tile extent, factor RHS sentinel, batch, cooperative block or explicit architecture",
    )
  }
  let size = request.tile_size
  // Reserved body storage plus POTRF status and validation flags. No MathDx
  // internal shared-memory budget or device occupancy is inferred from this.
  let matrix_bytes = size * size * width(request.dtype)
  let rhs_bytes = if request.operation == "factor-solve" {
    size * request.rhs_columns * width(request.dtype)
  } else {
    0
  }
  // Each explicitly 16-byte-aligned shared array can pad the previous one.
  let shared = (matrix_bytes + 15) / 16 * 16 + (rhs_bytes + 15) / 16 * 16 + 16
  guard shared <= 49152 else {
    raise Invalid(
      "explicit tile storage exceeds conservative 48 KiB body budget; tile sizes are not silently reduced",
    )
  }
  let area = if request.operation == "factor-solve" &&
    request.rhs_columns > size {
    size * request.rhs_columns
  } else {
    size * size
  }
  let largest = area * width(request.dtype)
  guard request.batch_size <= 268435456 / largest else {
    raise Invalid("tile owner exceeds 256 MiB pipeline capacity")
  }
  shared
}

///|
fn parameter(
  name : String,
  dtype : String,
  rank : Int32,
  access : String,
) -> Parameter {
  {
    name,
    c_type: "wp::array_t<wp::" + dtype + ">",
    kind: "array",
    dtype,
    rank,
    access,
  }
}

///|
/// Generates genuine cooperative cuSolverDx call sites. It does not open a
/// library, compile a shader or execute any numerical operation.
pub fn lower(request : Request) -> Lowered raise TileError {
  let shared = validate(request)
  let solve = request.operation == "factor-solve"
  let n = request.tile_size
  let k = request.rhs_columns
  let threads = request.block_dim
  let precision = if request.dtype == "float32" { 5 } else { 6 }
  let scalar = "wp::" + request.dtype
  let suffix = "\{n}_\{k}_\{request.architecture}_\{threads}_\{precision}"
  let potrf = "mr_mathdx_potrf_" + suffix
  let potrs = "mr_mathdx_potrs_" + suffix
  let forward = if solve {
    "mr_mathdx_tile_factor_solve"
  } else {
    "mr_mathdx_tile_factor"
  }
  let key = if solve {
    "mathdx-tile-factor-solve"
  } else {
    "mathdx-tile-factor"
  }
  let parameters = [parameter("matrix", request.dtype, 3, "input")]
  if solve {
    parameters.push(parameter("rhs", request.dtype, 3, "input"))
  }
  parameters.push(parameter("factor", request.dtype, 3, "output"))
  if solve {
    parameters.push(parameter("solution", request.dtype, 3, "output"))
  }
  parameters.push(parameter("status", "int32", 1, "output"))
  let declarations = parameters.map(p => p.c_type + " " + p.name).join(", ")
  let source = "// Genuine Warp 1.17 C ABI and cuSolverDx LTO functions; no scalar fallback.\n" +
    "#include \"builtin.h\"\n" +
    "static_assert(sizeof(wp::array_t<float>)==56,\"Warp array ABI\");\n" +
    "static_assert(sizeof(wp::launch_bounds_t<1>)==24,\"Warp bounds ABI\");\n" +
    "extern \"C\" __device__ void " +
    potrf +
    "(" +
    scalar +
    "*, int*);\n" +
    (if solve {
      "extern \"C\" __device__ void " +
      potrs +
      "(" +
      scalar +
      "*, " +
      scalar +
      "*);\n"
    } else {
      ""
    }) +
    "extern \"C\" __global__ void " +
    forward +
    "(wp::launch_bounds_t<1> bounds, " +
    declarations +
    ") {\n" +
    "  const size_t job = size_t(blockIdx.x) + size_t(gridDim.x)*(size_t(blockIdx.y)+size_t(gridDim.y)*size_t(blockIdx.z));\n" +
    "  if (job >= " +
    request.batch_size.to_string() +
    " || bounds.size != " +
    (request.batch_size * threads).to_string() +
    " || bounds.coord_mult != 1 || blockDim.x != " +
    threads.to_string() +
    ") return;\n" +
    "  const int lane = int(threadIdx.x);\n" +
    "  __shared__ __align__(16) " +
    scalar +
    " a[" +
    (n * n).to_string() +
    "];\n" +
    (if solve {
      "  __shared__ __align__(16) " +
      scalar +
      " b[" +
      (n * k).to_string() +
      "];\n"
    } else {
      ""
    }) +
    "  __shared__ int info; __shared__ int bad;\n" +
    "  if(lane==0) {info=0;bad=0;} __syncthreads();\n" +
    "  for(int slot=lane;slot<" +
    (n * n).to_string() +
    ";slot+=" +
    threads.to_string() +
    ") { a[slot]=matrix.data[job*" +
    (n * n).to_string() +
    "+slot]; if(!wp::isfinite(a[slot])) atomicExch(&bad,1); }\n" +
    (if solve {
      "  for(int slot=lane;slot<" +
      (n * k).to_string() +
      ";slot+=" +
      threads.to_string() +
      ") { b[slot]=rhs.data[job*" +
      (n * k).to_string() +
      "+slot]; if(!wp::isfinite(b[slot])) atomicExch(&bad,1); }\n"
    } else {
      ""
    }) +
    "  __syncthreads();\n" +
    "  if(bad==0) { " +
    potrf +
    "(a,&info); }\n" +
    "  __syncthreads();\n" +
    "  for(int slot=lane;slot<" +
    (n * n).to_string() +
    ";slot+=" +
    threads.to_string() +
    ") { const int row=slot/" +
    n.to_string() +
    ", col=slot%" +
    n.to_string() +
    "; if(row>col) a[slot]=0; else if(!wp::isfinite(a[slot]) || (row==col && a[slot]<=0)) atomicExch(&bad,1); }\n" +
    "  __syncthreads();\n" +
    (if solve {
      "  if(bad==0 && info==0) { " +
      potrs +
      "(a,b); }\n  __syncthreads();\n  for(int slot=lane;slot<" +
      (n * k).to_string() +
      ";slot+=" +
      threads.to_string() +
      ") { if(!wp::isfinite(b[slot])) atomicExch(&bad,1); }\n  __syncthreads();\n"
    } else {
      ""
    }) +
    "  const bool ok=(bad==0 && info==0);\n" +
    "  for(int slot=lane;slot<" +
    (n * n).to_string() +
    ";slot+=" +
    threads.to_string() +
    ") factor.data[job*" +
    (n * n).to_string() +
    "+slot]=ok?a[slot]:" +
    scalar +
    "(0);\n" +
    (if solve {
      "  for(int slot=lane;slot<" +
      (n * k).to_string() +
      ";slot+=" +
      threads.to_string() +
      ") solution.data[job*" +
      (n * k).to_string() +
      "+slot]=ok?b[slot]:" +
      scalar +
      "(0);\n"
    } else {
      ""
    }) +
    "  if(lane==0) status.data[job]=(info!=0)?info:((bad!=0)?-1:0);\n}\n"
  {
    request,
    source,
    source_sha256: @artifacts.sha256(@utf8.encode(source)),
    specialization_sha256: @artifacts.sha256(
      @utf8.encode(Json(request).stringify()),
    ),
    entries: [
      {
        key,
        forward,
        launch_shape: [request.batch_size * threads],
        parameters,
      },
    ],
    launch_policy: {
      block_dim: threads,
      forward_smem: 0,
      backward_smem: 0,
      grid_stride: false,
      coord_mult: 1,
    },
    static_shared_bytes: shared,
    potrf_symbol: potrf,
    potrs_symbol: if solve {
      Some(potrs)
    } else {
      None
    },
  }
}

///|
/// Host-only byte/shape proof for the exact cooperative tile entry. Status
/// bytes must additionally be read and all zero before publishing results.
pub fn validate_bindings(
  request : Request,
  entry_key : String,
  bindings : Array[Binding],
) -> Unit raise TileError {
  let lowered = lower(request)
  let entry = lowered.entries[0]
  guard entry_key == entry.key && bindings.length() == entry.parameters.length() else {
    raise Invalid("tile entry/binding cardinality mismatch")
  }
  let names : Map[String, Unit] = Map([])
  let owners : Map[String, Unit] = Map([])
  let parameters : Map[String, Parameter] = Map([])
  for parameter in entry.parameters {
    parameters[parameter.name] = parameter
  }
  for binding in bindings {
    guard !names.contains(binding.name) &&
      !binding.owner.is_empty() &&
      !owners.contains(binding.owner) else {
      raise Invalid(
        "tile arguments require distinct nonaliasing owners and unique names",
      )
    }
    names[binding.name] = ()
    owners[binding.owner] = ()
    guard parameters.get(binding.name) is Some(parameter) else {
      raise Invalid("unknown tile binding")
    }
    let shape = if binding.name == "status" {
      [request.batch_size]
    } else if binding.name == "rhs" || binding.name == "solution" {
      [request.batch_size, request.tile_size, request.rhs_columns]
    } else {
      [request.batch_size, request.tile_size, request.tile_size]
    }
    let element = if binding.name == "status" {
      4
    } else {
      width(request.dtype)
    }
    guard parameter.dtype == binding.dtype &&
      binding.shape == shape &&
      binding.byte_strides.length() == shape.length() &&
      binding.offset_bytes % element.to_uint64() == 0UL else {
      raise Invalid(
        "tile dtype, actual shape, offset alignment or stride rank mismatch",
      )
    }
    let mut bytes = element
    for index in 0..<shape.length() {
      let axis = shape.length() - 1 - index
      guard binding.byte_strides[axis] == bytes &&
        bytes <= 268435456 / shape[axis] else {
        raise Invalid(
          "tile requires exact C-contiguous layout and bounded footprint",
        )
      }
      bytes *= shape[axis]
    }
    guard binding.offset_bytes <= binding.capacity_bytes &&
      bytes.to_uint64() <= binding.capacity_bytes - binding.offset_bytes else {
      raise Invalid("tile reachable footprint exceeds actual owner")
    }
  }
}
