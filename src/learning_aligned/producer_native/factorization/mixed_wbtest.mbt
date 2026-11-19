///|
// Pending source-only regression cases. No numerical test has been executed.
fn mixed_fixture() -> MixedRequest {
  let parent = [-1, -1, 1, -1, 3, 3]
  let nnz = [1, 1, 2, 1, 2, 2]
  let adr = [0, 1, 2, 4, 5, 7]
  let col = [0, 1, 1, 2, 3, 3, 4, 3, 5]
  let matrix = [4.0, 4.0, 2.0, 5.0, 4.0, 1.0, 2.0, 1.0, 3.0]
  let factor_adr = [-2, 0, 0, 4, 4, 4]
  // This actual >64 tree remains packed sparse; the three earlier trees
  // exercise compact, scalar and branched <=6 gather paths simultaneously.
  for index in 0..<65 {
    let row = 6 + index
    parent.push(if index == 0 { -1 } else { 6 })
    adr.push(col.length())
    nnz.push(if index == 0 { 1 } else { 2 })
    if index > 0 {
      col.push(6)
      matrix.push(0.5)
    }
    col.push(row)
    matrix.push(if index == 0 { 100.0 } else { 2.0 })
    factor_adr.push(-1)
  }
  {
    layout: {
      tree_dofadr: [0, 0, 1, 3, 6],
      tree_dofnum: [0, 1, 2, 3, 65],
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
    matrix: [matrix],
    rhs: None,
    factor_seed: Some([Array::make(13 + col.length(), 9.0)]),
    inverse_diagonal_seed: Some([Array::make(parent.length(), 123.0)]),
    regularization: None,
    skip_worlds: None,
  }
}

///|
test "mixed actual trees retain scalar seeds, zero gather lower and full sparse tail" {
  let request = mixed_fixture()
  let factor = factor_mixed(request)
  assert_true(factor.plan.blocks[0].kind == Compact)
  assert_true(factor.plan.blocks[1].kind == Scalar)
  assert_true(factor.plan.blocks[2].kind == Gather)
  assert_true(factor.plan.blocks[3].kind == Sparse)
  let qld = factor.qld()[0]
  assert_eq(qld.length(), 13 + request.matrix[0].length())
  assert_eq(qld[2], 9.0)
  assert_eq(qld[4 + 3], 0.0)
  assert_eq(qld[4 + 6], 0.0)
  assert_eq(qld[4 + 7], 0.0)
  for address in 0..<9 {
    assert_eq(qld[13 + address], request.matrix[0][address])
  }
  close_rows([factor.inverse_diagonal()[0][0:6].to_owned()], [
    [0.25, 0.25, 0.2, 0.25, 0.5, 1.0 / 3.0],
  ])
  let rhs = [4.0, 6.0, 7.0, 6.0, 3.0, 4.0, 132.0]
  for _ in 0..<64 {
    rhs.push(2.5)
  }
  close_rows(factor.solve([rhs]), [Array::make(71, 1.0)])
  // Exports and request arrays cannot mutate retained state.
  qld[0] = -100.0
  request.matrix[0][0] = -100.0
  request.layout.tree_dofnum[1] = 999
  assert_eq(factor.qld()[0][0], 2.0)
  assert_eq(factor.plan.tree_num[1], 1)
}

///|
test "gather missing pair uses exact nC sentinel and no sparse D overwrite" {
  let request : MixedRequest = {
    layout: {
      tree_dofadr: [0],
      tree_dofnum: [3],
      dof_parentid: [-1, 0, 0],
      m_rownnz: [1, 2, 2],
      m_rowadr: [0, 1, 3],
      m_colind: [0, 0, 1, 0, 2],
      qLD_block_adr: [0, 0, 0],
      qLD_block_total: 9,
      blocks: [
        { start: 0, size: 3, elemid: Some([0, 1, 3, 1, 2, 5, 3, 5, 4]), },
      ],
    },
    matrix: [[4.0, 1.0, 2.0, 1.0, 3.0]],
    rhs: None,
    factor_seed: Some([Array::make(9, 9.0)]),
    inverse_diagonal_seed: Some([[123.0, 456.0, 789.0]]),
    regularization: None,
    skip_worlds: None,
  }
  let factor = factor_mixed(request)
  close_rows(factor.solve([[6.0, 3.0, 4.0]]), [[1.0, 1.0, 1.0]])
  assert_eq(factor.inverse_diagonal(), [[123.0, 456.0, 789.0]])
  let invalid = {
    ..request,
    layout: {
      ..request.layout,
      blocks: [
        { start: 0, size: 3, elemid: Some([0, 1, 3, 1, 2, 0, 3, 5, 4]), },
      ],
    },
  }
  let rejected = try {
    ignore(factor_mixed(invalid))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}

///|
test "gather keeps actual seven-DOF block rather than reducing tile size" {
  let request : MixedRequest = {
    layout: {
      tree_dofadr: [0],
      tree_dofnum: [7],
      dof_parentid: [-1, 0, 1, 2, 3, 4, 5],
      m_rownnz: [1, 1, 1, 1, 1, 1, 1],
      m_rowadr: [0, 1, 2, 3, 4, 5, 6],
      m_colind: [0, 1, 2, 3, 4, 5, 6],
      qLD_block_adr: Array::make(7, 0),
      qLD_block_total: 49,
      blocks: [{ start: 0, size: 7, elemid: None, }],
    },
    matrix: [Array::make(7, 4.0)],
    rhs: None,
    factor_seed: None,
    inverse_diagonal_seed: None,
    regularization: None,
    skip_worlds: None,
  }
  let factor = factor_mixed(request)
  assert_true(factor.plan.blocks[0].kind == Gather)
  assert_eq(factor.qld()[0].length(), 49)
  close_rows(factor.solve([Array::make(7, 8.0)]), [Array::make(7, 2.0)])
}

///|
test "mixed rejects invented partitions, cross-block coupling and wrong factor offsets" {
  let source = mixed_fixture()
  let partition = {
    ..source,
    layout: { ..source.layout, tree_dofnum: [0, 1, 2, 4, 64], },
  }
  let rejected = try {
    ignore(factor_mixed(partition))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  source.layout.m_colind[2] = 0
  let rejected = try {
    ignore(factor_mixed(source))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  let offset = mixed_fixture()
  offset.layout.qLD_block_adr[3] = 5
  let rejected = try {
    ignore(factor_mixed(offset))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}
