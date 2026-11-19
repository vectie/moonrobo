///|
// Pending host-only regression sources. None have been executed. No case
// opens a native library, compiles a shader, creates CUDA state or runs a solve.
fn fixture() -> Request {
  {
    operation: "factor-solve",
    dtype: "float64",
    tile_size: 8,
    rhs_columns: 2,
    batch_size: 3,
    block_dim: 64,
    architecture: 89,
  }
}

///|
fn fixture_bindings(request : Request) -> Array[Binding] {
  let n = request.tile_size
  let width = if request.dtype == "float64" { 8 } else { 4 }
  let result = []
  for name in ["matrix", "rhs", "factor", "solution", "status"] {
    let columns = if name == "rhs" || name == "solution" {
      request.rhs_columns
    } else {
      n
    }
    let status = name == "status"
    result.push({
      name,
      dtype: if status {
        "int32"
      } else {
        request.dtype
      },
      shape: if status {
        [request.batch_size]
      } else {
        [request.batch_size, n, columns]
      },
      byte_strides: if status {
        [4]
      } else {
        [n * columns * width, columns * width, width]
      },
      offset_bytes: 0UL,
      capacity_bytes: (if status {
        request.batch_size * 4
      } else {
        request.batch_size * n * columns * width
      }).to_uint64(),
      owner: name,
    })
  }
  result
}

///|
test "MathDx factor-solve shader uses real externs and one cooperative block per tile" {
  let lowered = lower(fixture())
  assert_eq(lowered.entries[0].key, "mathdx-tile-factor-solve")
  assert_eq(lowered.entries[0].launch_shape, [192])
  assert_eq(lowered.launch_policy.block_dim, 64)
  assert_eq(lowered.launch_policy.forward_smem, 0)
  assert_true(!lowered.launch_policy.grid_stride)
  assert_eq(lowered.static_shared_bytes, 656)
  assert_eq(lowered.entries[0].parameters.length(), 5)
  assert_true(lowered.source.contains("if(bad==0 && info==0)"))
  assert_true(lowered.source.contains("mr_mathdx_potrf_8_2_89_64_6"))
  assert_true(lowered.source.contains("mr_mathdx_potrs_8_2_89_64_6"))
  assert_true(lowered.source.contains("status.data[job]"))
  assert_true(!lowered.source.contains("scalar_cholesky"))
}

///|
test "factor-only supplies POTRF and status but no untrusted-factor solve" {
  let request = { ..fixture(), operation: "factor", rhs_columns: 1, }
  let lowered = lower(request)
  assert_eq(lowered.entries[0].key, "mathdx-tile-factor")
  assert_eq(lowered.entries[0].parameters.length(), 3)
  assert_true(lowered.potrs_symbol is None)
  assert_eq(lowered.static_shared_bytes, 528)
}

///|
test "tile binding proof rejects aliased outputs, partial layouts and wrong batch rank" {
  let request = fixture()
  let bindings = fixture_bindings(request)
  validate_bindings(request, "mathdx-tile-factor-solve", bindings)
  bindings[2] = { ..bindings[2], owner: "matrix", }
  let rejected = try {
    validate_bindings(request, "mathdx-tile-factor-solve", bindings)
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  let bindings = fixture_bindings(request)
  bindings[0].byte_strides[0] += 8
  let rejected = try {
    validate_bindings(request, "mathdx-tile-factor-solve", bindings)
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  let bindings = fixture_bindings(request)
  bindings[1] = { ..bindings[1], capacity_bytes: 1UL, }
  let rejected = try {
    validate_bindings(request, "mathdx-tile-factor-solve", bindings)
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  let bindings = fixture_bindings(request)
  bindings[4] = { ..bindings[4], shape: [3, 1], }
  let rejected = try {
    validate_bindings(request, "mathdx-tile-factor-solve", bindings)
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}

///|
test "unsupported GPU layouts and budgets fail before native compiler loading" {
  for
    request in [
      { ..fixture(), operation: "solve", },
      { ..fixture(), tile_size: 65, },
      { ..fixture(), block_dim: 17, },
      { ..fixture(), architecture: 129, },
      { ..fixture(), dtype: "float16", },
      { ..fixture(), tile_size: 64, rhs_columns: 64, },
      { ..fixture(), batch_size: 2147483647, },
      { ..fixture(), operation: "factor", rhs_columns: 2, },
    ] {
    let rejected = try {
      ignore(lower(request))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
}

///|
test "compile config rejects unknown nested fields without executing a compiler" {
  let config : CompileConfig = {
    request: fixture(),
    warp_library: "/explicit/warp.so",
    warp_native: "/explicit/warp/native",
    cuda_include_dirs: [],
    output: "/fresh/output",
  }
  let valid = decode_config(Json(config))
  assert_eq(valid.request.tile_size, 8)
  let value = Json(config)
  guard value is Object(fields) && fields["request"] is Object(request) else {
    fail("fixture encoding")
  }
  request["regularization"] = 0.001
  let rejected = try {
    ignore(decode_config(value))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}
