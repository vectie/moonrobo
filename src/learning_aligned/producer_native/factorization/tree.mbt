///|
fn csr(
  nnz : Array[Int32],
  adr : Array[Int32],
  col : Array[Int32],
) -> Unit raise FactorizationError {
  let nv = nnz.length()
  guard nv > 0 && nv <= 65536 && adr.length() == nv else {
    raise Invalid("CSR row metadata requires 1..65536 DOFs")
  }
  let mut cursor = 0
  for row in 0..<nv {
    guard nnz[row] > 0 &&
      adr[row] == cursor &&
      nnz[row] <= col.length() - cursor else {
      raise Invalid("CSR rows must cover contiguous nonempty packed storage")
    }
    let mut previous = -1
    for j in 0..<nnz[row] {
      let value = col[cursor + j]
      guard value > previous && value <= row else {
        raise Invalid(
          "CSR columns must be strictly increasing lower-triangle indices",
        )
      }
      previous = value
    }
    guard previous == row else {
      raise Invalid("CSR diagonal must be the last entry in every row")
    }
    cursor += nnz[row]
  }
  guard cursor == col.length() else {
    raise Invalid("CSR contains unclassified trailing entries")
  }
}

///|
fn tree_plan(layout : TreeLayout) -> TreePlan raise FactorizationError {
  csr(layout.m_rownnz, layout.m_rowadr, layout.m_colind)
  let nv = layout.m_rownnz.length()
  guard layout.dof_parentid.length() == nv &&
    layout.qLD_block_adr.length() == nv else {
    raise Invalid("tree parent/block metadata has the wrong DOF count")
  }
  guard layout.qLD_block_total == 0 &&
    layout.qLD_block_adr.all(value => value == -1) else {
    raise Unsupported(
      "tree fragment requires an all-sparse LDL region, without dense/compact block prefix",
    )
  }
  for k in 0..<nv {
    let parent = layout.dof_parentid[k]
    guard parent >= -1 && parent < k else {
      raise Invalid(
        "parent DOFs must precede their child or be the -1 root sentinel",
      )
    }
    let chain = []
    let mut p = k
    while p >= 0 {
      chain.push(p)
      p = layout.dof_parentid[p]
    }
    guard chain.length() == layout.m_rownnz[k] else {
      raise Unsupported(
        "sparse row is not the complete ancestor prefix; compact-in-sparse and arbitrary CSR are unsupported",
      )
    }
    for j in 0..<chain.length() {
      guard layout.m_colind[layout.m_rowadr[k] + j] ==
        chain[chain.length() - 1 - j] else {
        raise Unsupported(
          "sparse CSR row does not match the actual root-to-self ancestor prefix",
        )
      }
    }
  }
  let depth = Array::make(nv, -1)
  let groups : Map[Int32, Array[Update]] = Map([])
  for k in 0..<nv {
    if layout.m_rownnz[k] == 1 {
      continue
    }
    depth[k] = depth[layout.dof_parentid[k]] + 1
    let mut i = layout.dof_parentid[k]
    let mut address = layout.m_rowadr[k] + layout.m_rownnz[k] - 2
    while i >= 0 {
      let update : Update = { i, k, madr_ki: address, }
      match groups.get(depth[i]) {
        Some(values) => values.push(update)
        None => groups[depth[i]] = [update]
      }
      i = layout.dof_parentid[i]
      address -= 1
    }
  }
  let keys = groups.keys().collect()
  keys.sort()
  {
    parent: layout.dof_parentid.copy(),
    nnz: layout.m_rownnz.copy(),
    adr: layout.m_rowadr.copy(),
    col: layout.m_colind.copy(),
    levels: keys.map(key => groups[key].copy()),
  }
}

///|
/// Actual packed-tree L' D L factorization. No dense matrix is constructed.
/// Depth groups match pinned io.py and each group observes a barrier snapshot.
pub fn factor_tree(
  request : TreeRequest,
) -> TreeFactor raise FactorizationError {
  let plan = tree_plan(request.layout)
  let worlds = request.matrix.length()
  options(worlds, request.regularization, request.skip_worlds)
  check_rows(request.matrix, worlds, plan.col.length(), "matrix")
  let factors = rows_copy(request.matrix)
  let inverse_diagonal = []
  for world, row in factors {
    for step in 0..<plan.levels.length() {
      let updates = plan.levels[plan.levels.length() - 1 - step]
      let before = row.copy()
      for update in updates {
        let diag = plan.adr[update.k] + plan.nnz[update.k] - 1
        pivot(before[diag], world, update.k)
        let multiplier = before[update.madr_ki] / before[diag]
        guard finite(multiplier) else {
          raise Invalid("sparse factor multiplier overflow")
        }
        for j in 0..<plan.nnz[update.i] {
          let address = plan.adr[update.i] + j
          let value = row[address] - before[plan.adr[update.k] + j] * multiplier
          guard finite(value) else {
            raise Invalid("sparse LDL update overflow")
          }
          row[address] = value
        }
        row[update.madr_ki] = multiplier
      }
    }
    let inverse = []
    for i in 0..<plan.nnz.length() {
      let value = row[plan.adr[i] + plan.nnz[i] - 1]
      pivot(value, world, i)
      let reciprocal = 1.0 / value
      pivot(reciprocal, world, i)
      inverse.push(reciprocal)
    }
    inverse_diagonal.push(inverse)
  }
  { plan, factors, inverse_diagonal, }
}

///|
/// Sparse forward, reciprocal diagonal, backward substitution. This operates
/// only on the retained validated packed factors, not a dense surrogate.
pub fn TreeFactor::solve(
  self : TreeFactor,
  rhs : Array[Array[Double]],
) -> Array[Array[Double]] raise FactorizationError {
  let plan = self.plan
  check_rows(rhs, self.factors.length(), plan.nnz.length(), "rhs")
  let result = rows_copy(rhs)
  for world, x in result {
    let factors = self.factors[world]
    for step in 0..<plan.levels.length() {
      let updates = plan.levels[plan.levels.length() - 1 - step]
      let before = x.copy()
      for update in updates {
        x[update.i] -= factors[update.madr_ki] * before[update.k]
      }
    }
    for i in 0..<x.length() {
      x[i] *= self.inverse_diagonal[world][i]
    }
    for updates in plan.levels {
      let before = x.copy()
      for update in updates {
        x[update.k] -= factors[update.madr_ki] * before[update.i]
      }
    }
    guard x.all(finite) else {
      raise Invalid("sparse triangular solve overflow")
    }
  }
  result
}

///|
pub fn TreeFactor::qld(self : TreeFactor) -> Array[Array[Double]] {
  rows_copy(self.factors)
}

///|
pub fn TreeFactor::inverse_diagonal(self : TreeFactor) -> Array[Array[Double]] {
  rows_copy(self.inverse_diagonal)
}

///|
pub fn TreeFactor::data(self : TreeFactor) -> Json {
  let updates = []
  let offsets = [0]
  for level in self.plan.levels {
    for update in level {
      updates.push(update)
    }
    offsets.push(updates.length())
  }
  let dummy : Update = { i: 0, k: 0, madr_ki: 0, }
  {
    "qLD": Json(self.factors),
    "qLDiagInv": Json(self.inverse_diagonal),
    "qLD_updates": Json(self.plan.levels),
    "qLD_all_updates": Json(if updates.is_empty() { [dummy] } else { updates }),
    "qLD_level_offsets": Json(offsets),
    "dof_parentid": Json(self.plan.parent),
    "M_rownnz": Json(self.plan.nnz),
    "M_rowadr": Json(self.plan.adr),
    "M_colind": Json(self.plan.col),
    "storage": "packed-ancestor-CSR",
    "factorization": "L-transpose-D-L",
  }
}
