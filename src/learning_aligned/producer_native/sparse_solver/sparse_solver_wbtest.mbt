///|
// Pending source-only tests. No test, lowerer, compiler or numerical algorithm
// was executed while authoring these cases.
fn mixed_fixture() -> Request {
  let parent = [-1, -1, 1, -1, 3, 3]
  let nnz = [1, 1, 2, 1, 2, 2]
  let adr = [0, 1, 2, 4, 5, 7]
  let col = [0, 1, 1, 2, 3, 3, 4, 3, 5]
  let factor_adr = [-2, 0, 0, 4, 4, 4]
  for index in 0..<65 {
    let row = 6 + index
    parent.push(if index == 0 { -1 } else { 6 })
    adr.push(col.length())
    nnz.push(if index == 0 { 1 } else { 2 })
    if index > 0 {
      col.push(6)
    }
    col.push(row)
    factor_adr.push(-1)
  }
  {
    dtype: "float64",
    nworld: 3,
    block_dim: 128,
    architecture: 89,
    check_done: true,
    layout: {
      tree_dofadr: [0, 1, 3, 6],
      tree_dofnum: [1, 2, 3, 65],
      dof_parentid: parent,
      m_rownnz: nnz,
      m_rowadr: adr,
      m_colind: col,
      qLD_block_adr: factor_adr,
      qLD_block_total: 13,
      blocks: [
        { start: 0, size: 1, elemid: None, },
        { start: 1, size: 2, elemid: None, },
        { start: 3, size: 3, elemid: None, },
        { start: 6, size: 65, elemid: None, },
      ],
    },
  }
}

///|
fn fixture_bindings(r : Request, key : String) -> Array[Binding] raise {
  let lowered = lower(r)
  let shapes : Map[String, Array[Int32]] = Map([])
  for item in lowered.metadata {
    shapes[item.name] = item.shape
  }
  shapes["matrix"] = [r.nworld, lowered.nC]
  shapes["factor"] = [r.nworld, lowered.factor_width]
  for name in ["diagonal", "rhs", "solution"] {
    shapes[name] = [r.nworld, lowered.nv]
  }
  shapes["done"] = [r.nworld]
  shapes["failure"] = [r.nworld]
  let entries : Map[String, Entry] = Map([])
  for entry in lowered.entries {
    entries[entry.key] = entry
  }
  entries[key].parameters.map(p => {
    let shape = shapes[p.name]
    let strides = Array::make(shape.length(), 0)
    let mut bytes = scalar_width(p.dtype)
    for index in 0..<shape.length() {
      let axis = shape.length() - 1 - index
      strides[axis] = bytes
      bytes *= shape[axis]
    }
    {
      name: p.name,
      dtype: p.dtype,
      shape,
      byte_strides: strides,
      offset_bytes: 0UL,
      capacity_bytes: bytes.to_uint64(),
      owner: p.name,
    }
  })
}

///|
test "mixed GPU source closes compact scalar gather and full sparse tail" {
  let r = mixed_fixture()
  let lowered = lower(r)
  assert_eq(lowered.nv, 71)
  assert_eq(lowered.nC, 138)
  assert_eq(lowered.factor_width, 151)
  assert_eq(lowered.sparse_levels, 1)
  assert_eq(lowered.entries.length(), 3)
  assert_eq(lowered.entries[0].launch_shape, [384])
  assert_true(!lowered.launch_policy.grid_stride)
  assert_true(lowered.source.contains("wp::tile_cholesky_inplace<true>(0,A)"))
  assert_true(
    lowered.source.contains("wp::tile_cholesky_solve_inplace<true>(0,A,B)"),
  )
  assert_true(lowered.source.contains("__shared__ int entry_skip"))
  assert_true(lowered.source.contains("for(int reverse=0;reverse<MR_LEVELS"))
  assert_true(
    lowered.source.contains("wp::atomic_sub(factor,w,MR_PREFIX+ai+j,value)"),
  )
  assert_eq(lowered.metadata.length(), 7)
  validate_initial_failure(r.nworld, Bytes::make(12, 0))
}

///|
test "actual metadata bytes must match immutable model indices exactly" {
  let r = mixed_fixture()
  let lowered = lower(r)
  let actual = lowered.metadata.map(item => MetadataInput::{
    name: item.name,
    bytes: item.bytes,
  })
  validate_metadata(r, "mixed-factor-solve", actual)
  actual[0] = { name: "row_nnz", bytes: b"wrong bytes", }
  let rejected = try {
    validate_metadata(r, "mixed-factor-solve", actual)
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  let bad = Bytes::make(12, 1)
  let rejected = try {
    validate_initial_failure(r.nworld, bad)
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}

///|
test "mixed exact rhs solution in-place is allowed and all other aliasing fails" {
  let r = mixed_fixture()
  let key = "mixed-solve"
  let bindings = fixture_bindings(r, key)
  let mut rhs_index = 0
  let mut solution_index = 0
  let mut factor_index = 0
  for index, b in bindings {
    if b.name == "rhs" {
      rhs_index = index
    }
    if b.name == "solution" {
      solution_index = index
    }
    if b.name == "factor" {
      factor_index = index
    }
  }
  bindings[solution_index] = { ..bindings[solution_index], owner: "rhs", }
  validate_bindings(r, key, bindings)
  bindings[solution_index] = {
    ..bindings[solution_index],
    offset_bytes: 8UL,
    capacity_bytes: bindings[rhs_index].capacity_bytes + 8UL,
  }
  let rejected = try {
    validate_bindings(r, key, bindings)
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  let bindings = fixture_bindings(r, key)
  bindings[factor_index] = { ..bindings[factor_index], owner: "diagonal", }
  let rejected = try {
    validate_bindings(r, key, bindings)
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}

///|
test "compact-only source requires no empty factor allocation" {
  let r : Request = {
    dtype: "float32",
    nworld: 2,
    block_dim: 32,
    architecture: 80,
    check_done: false,
    layout: {
      tree_dofadr: [0],
      tree_dofnum: [2],
      dof_parentid: [-1, 0],
      m_rownnz: [1, 1],
      m_rowadr: [0, 1],
      m_colind: [0, 1],
      qLD_block_adr: [-2, -2],
      qLD_block_total: 0,
      blocks: [{ start: 0, size: 2, elemid: None, }],
    },
  }
  let lowered = lower(r)
  assert_eq(lowered.factor_width, 0)
  for entry in lowered.entries {
    assert_true(!entry.parameters.any(p => p.name == "factor"))
    assert_true(!entry.parameters.any(p => p.name == "done"))
  }
  assert_eq(lowered.metadata[4].shape, [1])
}

///|
fn lu_fixture() -> LuRequest {
  {
    dtype: "float32",
    nworld: 2,
    block_dim: 64,
    architecture: 89,
    check_done: true,
    layout: {
      d_rownnz: [2, 2],
      d_rowadr: [0, 2],
      d_diag: [0, 1],
      d_colind: [0, 1, 0, 1],
    },
  }
}

///|
test "sparse LU preserves actual reverse elimination and relative diagonal addresses" {
  let lowered = lower_lu(lu_fixture())
  assert_eq(lowered.nD, 4)
  assert_eq(lowered.entries[0].launch_shape, [128])
  assert_true(lowered.source.contains("MR_NV-1-reverse"))
  assert_true(lowered.source.contains("value/=denominator"))
  assert_eq(lowered.metadata[2].name, "d_diag")
  let invalid = {
    ..lu_fixture(),
    layout: { ..lu_fixture().layout, d_diag: [0, 3], },
  }
  let rejected = try {
    ignore(lower_lu(invalid))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}

///|
test "sparse LU refuses dropped fill and refuses rhs scratch aliasing" {
  let invalid : LuRequest = {
    ..lu_fixture(),
    layout: {
      d_rownnz: [2, 1, 2],
      d_rowadr: [0, 2, 3],
      d_diag: [0, 0, 1],
      d_colind: [0, 2, 1, 1, 2],
    },
  }
  let rejected = try {
    ignore(lower_lu(invalid))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  let r = lu_fixture()
  let lowered = lower_lu(r)
  let shapes : Map[String, Array[Int32]] = Map([])
  for item in lowered.metadata {
    shapes[item.name] = item.shape
  }
  shapes["rhs"] = [2, 2]
  shapes["solution"] = [2, 2]
  shapes["lu"] = [2, 4]
  shapes["failure"] = [2]
  shapes["done"] = [2]
  let bindings = lowered.entries[0].parameters.map(p => {
    let shape = shapes[p.name]
    let strides = Array::make(shape.length(), 0)
    let mut bytes = scalar_width(p.dtype)
    for index in 0..<shape.length() {
      let axis = shape.length() - 1 - index
      strides[axis] = bytes
      bytes *= shape[axis]
    }
    {
      name: p.name,
      dtype: p.dtype,
      shape,
      byte_strides: strides,
      offset_bytes: 0UL,
      capacity_bytes: bytes.to_uint64(),
      owner: if p.name == "solution" {
        "rhs"
      } else {
        p.name
      },
    }
  })
  let rejected = try {
    validate_lu_bindings(r, "sparse-lu-factor-solve", bindings)
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}
