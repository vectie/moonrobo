///|
fn scalar_width(dtype : String) -> Int32 raise SolverError {
  match dtype {
    "float32" | "int32" => 4
    "float64" => 8
    "bool" => 1
    _ => raise Invalid("unsupported solver scalar ABI")
  }
}

///|
fn dimensions(
  dtype : String,
  nworld : Int32,
  threads : Int32,
  architecture : Int32,
  nv : Int32,
  width : Int32,
) -> Unit raise SolverError {
  guard dtype == "float32" || dtype == "float64" else {
    raise Invalid("solver supports genuine float32/float64 only")
  }
  guard nworld > 0 &&
    threads >= 32 &&
    threads <= 1024 &&
    threads % 32 == 0 &&
    nworld <= 2147483647 / threads &&
    nv > 0 &&
    nv <= 65536 &&
    width >= 0 &&
    [60, 61, 62, 70, 72, 75, 80, 86, 87, 89, 90, 100, 103, 110, 120, 121].contains(
      architecture,
    ) else {
    raise Invalid(
      "unsupported explicit world count, cooperative block, DOFs or architecture",
    )
  }
  let element = scalar_width(dtype)
  guard width == 0 ||
    (width <= 268435456 / element && nworld <= 268435456 / element / width) else {
    raise Invalid("solver numeric owner exceeds 256 MiB")
  }
}

///|
fn integers(
  name : String,
  shape : Array[Int32],
  values : Array[Int32],
) -> Metadata {
  let bytes = []
  for value in values {
    let bits = value.reinterpret_as_uint()
    for index in 0..<4 {
      bytes.push(((bits >> (8 * index)) & 255U).to_byte())
    }
  }
  let bytes = Bytes::from_array(bytes)
  { name, dtype: "int32", shape, bytes, sha256: @artifacts.sha256(bytes), }
}

///|
fn metadata(plan : @factorization.LayoutPlan) -> Array[Metadata] {
  let blocks = []
  let gathered = []
  for block in plan.blocks {
    let offset = gathered.length()
    for index in block.elemid {
      gathered.push(index)
    }
    let kind = match block.kind {
      "compact" => 0
      "scalar" => 1
      "gather" => 2
      _ => 3
    }
    for value in [block.start, block.size, kind, block.factor_adr, offset] {
      blocks.push(value)
    }
  }
  let updates = []
  let offsets = [0]
  for level in plan.levels {
    for update in level {
      updates.push(update.i)
      updates.push(update.k)
      updates.push(update.madr_ki)
    }
    offsets.push(updates.length() / 3)
  }
  if gathered.is_empty() {
    gathered.push(plan.nC)
  }
  if updates.is_empty() {
    for _ in 0..<3 {
      updates.push(0)
    }
  }
  [
    integers("row_nnz", [plan.nv], plan.row_nnz),
    integers("row_adr", [plan.nv], plan.row_adr),
    integers("factor_adr", [plan.nv], plan.factor_adr),
    integers("blocks", [plan.blocks.length(), 5], blocks),
    integers("gather_indices", [gathered.length()], gathered),
    integers("updates", [updates.length() / 3, 3], updates),
    integers("level_offsets", [offsets.length()], offsets),
  ]
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
    c_type: "wp::array_t<" +
    (if dtype == "bool" { "bool" } else { "wp::" + dtype }) +
    ">",
    kind: "array",
    dtype,
    rank,
    access,
  }
}

///|
fn parameters(
  request : Request,
  plan : @factorization.LayoutPlan,
  key : String,
) -> Array[Parameter] {
  let factor = key != "mixed-solve"
  let solve = key != "mixed-factor"
  let params = metadata(plan).map(item => {
    parameter(item.name, "int32", item.shape.length(), "input")
  })
  if factor {
    params.push(parameter("matrix", request.dtype, 2, "input"))
  }
  if plan.factor_width > 0 {
    params.push(
      parameter(
        "factor",
        request.dtype,
        2,
        if factor {
          "inout"
        } else {
          "input"
        },
      ),
    )
  }
  params.push(
    parameter(
      "diagonal",
      request.dtype,
      2,
      if factor {
        "inout"
      } else {
        "input"
      },
    ),
  )
  if solve {
    params.push(parameter("rhs", request.dtype, 2, "input"))
    params.push(parameter("solution", request.dtype, 2, "inout"))
  }
  params.push(parameter("failure", "int32", 1, "inout"))
  if request.check_done {
    params.push(parameter("done", "bool", 1, "input"))
  }
  params
}

///|
pub fn callable_map() -> Json {
  {
    "source": "mujoco_warp3.15.0/smooth.py",
    "factor": "mixed-factor",
    "solve_LD": "mixed-solve",
    "solve_m": "mixed-solve",
    "factor_solve_i": "mixed-factor-solve",
    "factor_i_sparse": "mixed-factor(full-nC-tail branch)",
    "factor_blocks": "mixed-factor(compact/scalar/gather branch)",
    "solve_LD_sparse_fused": "mixed-solve(UP-D-DOWN branch)",
    "factor_solve_lu": "sparse-lu-factor-solve",
    "status": "failure:sticky-int32[world]",
    "mathdx_accelerated": false,
    "gpu_backend": "genuine-Warp-cooperative-scalar-tile-and-native-atomic-CSR",
    "runtime_equivalence_verified": false,
  }
}
