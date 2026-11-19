///|
fn csr_slot(
  adr : Array[Int32],
  nnz : Array[Int32],
  col : Array[Int32],
  i : Int32,
  j : Int32,
) -> Int32 {
  let row = if i > j { i } else { j }
  let column = if i > j { j } else { i }
  let mut low = adr[row]
  let mut high = low + nnz[row]
  while low < high {
    let middle = low + (high - low) / 2
    if col[middle] < column {
      low = middle + 1
    } else {
      high = middle
    }
  }
  if low < adr[row] + nnz[row] && col[low] == column {
    low
  } else {
    col.length()
  }
}

///|
fn mixed_plan(layout : MixedLayout) -> MixedPlan raise FactorizationError {
  csr(layout.m_rownnz, layout.m_rowadr, layout.m_colind)
  let nv = layout.m_rownnz.length()
  guard layout.dof_parentid.length() == nv &&
    layout.qLD_block_adr.length() == nv &&
    layout.qLD_block_total >= 0 else {
    raise Invalid("mixed parent/factor metadata cardinality")
  }
  guard layout.tree_dofadr.length() == layout.tree_dofnum.length() else {
    raise Invalid("actual tree metadata cardinality")
  }
  let actual_blocks = []
  for tree in 0..<layout.tree_dofnum.length() {
    let size = layout.tree_dofnum[tree]
    guard size >= 0 else { raise Invalid("negative actual tree DOF count") }
    if size > 0 {
      actual_blocks.push((layout.tree_dofadr[tree], size))
    }
  }
  guard actual_blocks.length() == layout.blocks.length() else {
    raise Invalid("blocks differ from actual nonempty compiled-model trees")
  }
  let kinds = Array::make(nv, Sparse)
  let blocks = []
  let mut dof_cursor = 0
  let mut factor_cursor = 0
  let mut has_sparse = false
  for index, block in layout.blocks {
    guard actual_blocks[index] == (block.start, block.size) else {
      raise Invalid(
        "block boundaries differ from actual tree_dofadr/tree_dofnum",
      )
    }
    guard block.start == dof_cursor &&
      block.size > 0 &&
      block.size <= nv - dof_cursor else {
      raise Invalid("mixed blocks must cover actual DOFs once in model order")
    }
    let end = block.start + block.size
    for row in block.start..<end {
      let parent = layout.dof_parentid[row]
      guard parent == -1 || (parent >= block.start && parent < row) else {
        raise Unsupported(
          "a mixed factor block crosses its actual ancestor tree boundary",
        )
      }
      for
        slot in layout.m_rowadr[row]..<(layout.m_rowadr[row] +
        layout.m_rownnz[row]) {
        guard layout.m_colind[slot] >= block.start else {
          raise Unsupported("CSR couples declared independent mixed blocks")
        }
      }
    }
    let nnz = layout.m_rowadr[end - 1] +
      layout.m_rownnz[end - 1] -
      layout.m_rowadr[block.start]
    let compact = nnz == block.size
    let triangular = nnz.to_int64() ==
      block.size.to_int64() * (block.size.to_int64() + 1L) / 2L
    let kind = if block.size <= 6 && compact {
      Compact
    } else if block.size <= 6 && triangular {
      Scalar
    } else if block.size <= 64 {
      Gather
    } else {
      Sparse
    }
    let expected_adr = match kind {
      Compact => -2
      Sparse => -1
      Scalar | Gather => factor_cursor
    }
    for row in block.start..<end {
      guard layout.qLD_block_adr[row] == expected_adr else {
        raise Invalid(
          "qLD block sentinel/offset differs from pinned m_block_layout policy",
        )
      }
      kinds[row] = kind
    }
    let indices = if kind == Gather {
      Array::makei(block.size * block.size, slot => {
        csr_slot(
          layout.m_rowadr,
          layout.m_rownnz,
          layout.m_colind,
          block.start + slot / block.size,
          block.start + slot % block.size,
        )
      })
    } else {
      []
    }
    if block.elemid is Some(provided) {
      guard provided == indices else {
        raise Invalid(
          "actual per-block gather indices differ from CSR including nC missing-pair sentinel",
        )
      }
    }
    if kind == Scalar || kind == Gather {
      factor_cursor += block.size * block.size
    }
    if kind == Sparse {
      has_sparse = true
      for row in block.start..<end {
        // A diagonal-only row has no _qLD_acc updates, even if its DOF parent
        // is non-root. For every nontrivial row prove the exact source reads.
        if layout.m_rownnz[row] == 1 {
          continue
        }
        let chain = []
        let mut node = row
        while node >= 0 {
          chain.push(node)
          node = layout.dof_parentid[node]
        }
        guard chain.length() == layout.m_rownnz[row] else {
          raise Unsupported(
            "large sparse row is not a complete ancestor prefix",
          )
        }
        for j in 0..<chain.length() {
          guard layout.m_colind[layout.m_rowadr[row] + j] ==
            chain[chain.length() - 1 - j] else {
            raise Unsupported(
              "large sparse row columns differ from its ancestor chain",
            )
          }
        }
        let mut parent = layout.dof_parentid[row]
        while parent >= 0 {
          for j in 0..<layout.m_rownnz[parent] {
            guard layout.m_colind[layout.m_rowadr[parent] + j] ==
              layout.m_colind[layout.m_rowadr[row] + j] else {
              raise Unsupported(
                "compact ancestor inside sparse update has incompatible row-prefix reads",
              )
            }
          }
          parent = layout.dof_parentid[parent]
        }
      }
    }
    blocks.push({ start: block.start, size: block.size, kind, elemid: indices, })
    dof_cursor = end
  }
  guard dof_cursor == nv && factor_cursor == layout.qLD_block_total else {
    raise Invalid("mixed block coverage or dense factor prefix total differs")
  }
  guard factor_cursor <=
    2147483647 - (if has_sparse { layout.m_colind.length() } else { 0 }) else {
    raise Invalid("mixed factor storage size overflows")
  }
  let depth = Array::make(nv, -1)
  let groups : Map[Int32, Array[Update]] = Map([])
  for k in 0..<nv {
    if layout.m_rownnz[k] == 1 {
      continue
    }
    let parent = layout.dof_parentid[k]
    guard parent >= 0 else {
      raise Invalid("nontrivial row lacks a DOF parent")
    }
    depth[k] = depth[parent] + 1
    if kinds[k] != Sparse {
      continue
    }
    let mut i = parent
    let mut address = layout.m_rowadr[k] + layout.m_rownnz[k] - 2
    while i >= 0 {
      guard kinds[i] == Sparse &&
        address >= layout.m_rowadr[k] &&
        layout.m_colind[address] == i else {
        raise Invalid(
          "sparse update escaped its validated block or actual CSR address",
        )
      }
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
    tree_adr: layout.tree_dofadr.copy(),
    tree_num: layout.tree_dofnum.copy(),
    parent: layout.dof_parentid.copy(),
    nnz: layout.m_rownnz.copy(),
    adr: layout.m_rowadr.copy(),
    col: layout.m_colind.copy(),
    factor_adr: layout.qLD_block_adr.copy(),
    total: factor_cursor,
    has_sparse,
    blocks,
    levels: keys.map(key => groups[key].copy()),
  }
}
