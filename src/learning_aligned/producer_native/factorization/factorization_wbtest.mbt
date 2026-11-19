///|
// Pending source-only regression cases. None have been executed.
fn tree_fixture(
  parent : Array[Int32],
  nnz : Array[Int32],
  adr : Array[Int32],
  col : Array[Int32],
  matrix : Array[Double],
) -> TreeRequest {
  {
    layout: {
      dof_parentid: parent,
      m_rownnz: nnz,
      m_rowadr: adr,
      m_colind: col,
      qLD_block_adr: Array::make(parent.length(), -1),
      qLD_block_total: 0,
    },
    matrix: [matrix],
    rhs: None,
    regularization: None,
    skip_worlds: None,
  }
}

///|
fn close_rows(
  actual : Array[Array[Double]],
  expected : Array[Array[Double]],
) -> Unit raise {
  assert_eq(actual.length(), expected.length())
  for world, row in actual {
    assert_eq(row.length(), expected[world].length())
    for i, value in row {
      assert_true((value - expected[world][i]).abs() < 0.000000000001)
    }
  }
}

///|
test "packed sparse LDL solves a genuine branched ancestor tree" {
  let request = tree_fixture(
    [-1, 0, 0],
    [1, 2, 2],
    [0, 1, 3],
    [0, 0, 1, 0, 2],
    [4.0, 1.0, 2.0, 1.0, 3.0],
  )
  let factor = factor_tree(request)
  close_rows(factor.solve([[6.0, 3.0, 4.0]]), [[1.0, 1.0, 1.0]])
  assert_eq(factor.plan.levels.length(), 1)
  assert_true(
    factor.plan.levels[0] ==
    [{ i: 0, k: 1, madr_ki: 1, }, { i: 0, k: 2, madr_ki: 3, }],
  )
}

///|
test "multi-level LDL preserves depth barriers and owns matrix copies" {
  let request = tree_fixture(
    [-1, 0, 1],
    [1, 2, 3],
    [0, 1, 3],
    [0, 0, 1, 0, 1, 2],
    [4.0, 1.0, 3.0, 0.5, 0.25, 2.0],
  )
  let factor = factor_tree(request)
  request.matrix[0][0] = -999.0
  let exported = factor.qld()
  exported[0][0] = -999.0
  close_rows(factor.solve([[5.5, 4.25, 2.75]]), [[1.0, 1.0, 1.0]])
}

///|
test "non-prefix CSR and mixed sparse/block layouts are refused" {
  let request = tree_fixture(
    [-1, 0, 1],
    [1, 2, 2],
    [0, 1, 3],
    [0, 0, 1, 1, 2],
    [4.0, 1.0, 3.0, 0.25, 2.0],
  )
  let rejected = try {
    ignore(factor_tree(request))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  let valid = tree_fixture([-1], [1], [0], [0], [4.0])
  valid.layout.qLD_block_adr[0] = -2
  let rejected = try {
    ignore(factor_tree(valid))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}

///|
test "small upper Cholesky preserves unused lower-factor and diagonal seeds" {
  let request : BlockRequest = {
    layout: {
      m_rownnz: [1, 2],
      m_rowadr: [0, 1],
      m_colind: [0, 0, 1],
      qLD_block_adr: [0, 0],
      qLD_block_total: 4,
      blocks: [{ start: 0, size: 2, }],
    },
    matrix: [[4.0, 2.0, 5.0]],
    rhs: None,
    factor_seed: Some([[7.0, 7.0, 9.0, 7.0]]),
    inverse_diagonal_seed: Some([[123.0, 456.0]]),
    regularization: None,
    skip_worlds: None,
  }
  let factor = factor_small_blocks(request)
  close_rows(factor.qld(), [[2.0, 1.0, 9.0, 2.0]])
  close_rows(factor.inverse_diagonal(), [[123.0, 456.0]])
  close_rows(factor.solve([[6.0, 7.0]]), [[1.0, 1.0]])
}

///|
test "compact diagonal block uses reciprocal storage without a dense factor" {
  let request : BlockRequest = {
    layout: {
      m_rownnz: [1, 1],
      m_rowadr: [0, 1],
      m_colind: [0, 1],
      qLD_block_adr: [-2, -2],
      qLD_block_total: 0,
      blocks: [{ start: 0, size: 2, }],
    },
    matrix: [[4.0, 5.0]],
    rhs: None,
    factor_seed: None,
    inverse_diagonal_seed: None,
    regularization: None,
    skip_worlds: None,
  }
  let factor = factor_small_blocks(request)
  assert_eq(factor.qld(), [[]])
  close_rows(factor.solve([[8.0, 15.0]]), [[2.0, 3.0]])
}

///|
test "zero pivots, nonzero regularization and skipped worlds never silently clamp" {
  let zero = tree_fixture([-1], [1], [0], [0], [0.0])
  let rejected = try {
    ignore(factor_tree(zero))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  let source = tree_fixture([-1], [1], [0], [0], [4.0])
  let regularized = { ..source, regularization: Some(0.01), }
  let rejected = try {
    ignore(factor_tree(regularized))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  let skipped = { ..source, skip_worlds: Some([true]), }
  let rejected = try {
    ignore(factor_tree(skipped))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}
