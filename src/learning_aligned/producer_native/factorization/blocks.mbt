///|
fn block_plan(layout : BlockLayout) -> BlockPlan raise FactorizationError {
  csr(layout.m_rownnz, layout.m_rowadr, layout.m_colind)
  let nv = layout.m_rownnz.length()
  guard layout.qLD_block_adr.length() == nv && layout.qLD_block_total >= 0 else {
    raise Invalid("block factor metadata has the wrong DOF count or total")
  }
  let mut dof_cursor = 0
  let mut factor_cursor = 0
  for block in layout.blocks {
    guard block.start == dof_cursor &&
      block.size > 0 &&
      block.size <= nv - dof_cursor else {
      raise Invalid(
        "independent block ranges must cover every DOF exactly once in model order",
      )
    }
    guard block.size <= 6 else {
      raise Unsupported(
        "tile/gather and augmented blocked Cholesky are not implemented by the small-block fragment",
      )
    }
    let address = layout.qLD_block_adr[block.start]
    guard address == -2 || address >= 0 else {
      raise Unsupported("mixed sparse/dense factor closure is not implemented")
    }
    for local_row in 0..<block.size {
      let row = block.start + local_row
      guard layout.qLD_block_adr[row] == address else {
        raise Invalid(
          "one small block must have one factor offset or compact sentinel",
        )
      }
      if address == -2 {
        guard layout.m_rownnz[row] == 1 &&
          layout.m_colind[layout.m_rowadr[row]] == row else {
          raise Invalid(
            "compact block must contain only its actual diagonal CSR entries",
          )
        }
      } else {
        guard layout.m_rownnz[row] == local_row + 1 else {
          raise Unsupported(
            "small full block requires complete local_row packed lower triangle",
          )
        }
        for j in 0..<=local_row {
          guard layout.m_colind[layout.m_rowadr[row] + j] == block.start + j else {
            raise Unsupported(
              "small block CSR columns do not match the contiguous triangular source layout",
            )
          }
        }
      }
    }
    if address >= 0 {
      guard address == factor_cursor else {
        raise Invalid(
          "packed factor offsets must match the actual contiguous row-major block layout",
        )
      }
      factor_cursor += block.size * block.size
    }
    dof_cursor += block.size
  }
  guard dof_cursor == nv && factor_cursor == layout.qLD_block_total else {
    raise Invalid("block coverage or packed factor total differs from metadata")
  }
  {
    nnz: layout.m_rownnz.copy(),
    adr: layout.m_rowadr.copy(),
    col: layout.m_colind.copy(),
    factor_adr: layout.qLD_block_adr.copy(),
    total: factor_cursor,
    blocks: layout.blocks.copy(),
  }
}

///|
/// Direct port of the compact reciprocal / scalar upper Cholesky branches.
/// Only independent blocks of at most six DOFs are supported; no dense global
/// solve is substituted for the sparse tree factorization.
pub fn factor_small_blocks(
  request : BlockRequest,
) -> BlockFactor raise FactorizationError {
  let plan = block_plan(request.layout)
  let worlds = request.matrix.length()
  options(worlds, request.regularization, request.skip_worlds)
  check_rows(request.matrix, worlds, plan.col.length(), "matrix")
  let factors = match request.factor_seed {
    Some(seed) => {
      check_rows(seed, worlds, plan.total, "factor_seed")
      rows_copy(seed)
    }
    None => Array::makei(worlds, _ => Array::make(plan.total, 0.0))
  }
  let inverse_diagonal = match request.inverse_diagonal_seed {
    Some(seed) => {
      check_rows(seed, worlds, plan.nnz.length(), "inverse_diagonal_seed")
      rows_copy(seed)
    }
    None => Array::makei(worlds, _ => Array::make(plan.nnz.length(), 0.0))
  }
  for world, matrix in request.matrix {
    let factor = factors[world]
    for block in plan.blocks {
      let address = plan.factor_adr[block.start]
      let input = plan.adr[block.start]
      let size = block.size
      if address == -2 {
        for i in 0..<size {
          let value = matrix[input + i]
          pivot(value, world, block.start + i)
          let inverse = 1.0 / value
          pivot(inverse, world, block.start + i)
          inverse_diagonal[world][block.start + i] = inverse
        }
      } else {
        for i in 0..<size {
          let mut value = matrix[input + i * (i + 1) / 2 + i]
          for k in 0..<i {
            let v = factor[address + k * size + i]
            value -= v * v
          }
          pivot(value, world, block.start + i)
          let diagonal = value.sqrt()
          pivot(diagonal, world, block.start + i)
          factor[address + i * size + i] = diagonal
          let inverse = 1.0 / diagonal
          pivot(inverse, world, block.start + i)
          for j in (i + 1)..<size {
            let mut value = matrix[input + j * (j + 1) / 2 + i]
            for k in 0..<i {
              value -= factor[address + k * size + i] *
                factor[address + k * size + j]
            }
            let result = value * inverse
            guard finite(result) else {
              raise Invalid("small Cholesky off-diagonal overflow")
            }
            factor[address + i * size + j] = result
          }
        }
      }
    }
  }
  { plan, factors, inverse_diagonal, }
}

///|
pub fn BlockFactor::solve(
  self : BlockFactor,
  rhs : Array[Array[Double]],
) -> Array[Array[Double]] raise FactorizationError {
  check_rows(rhs, self.factors.length(), self.plan.nnz.length(), "rhs")
  let result = rows_copy(rhs)
  for world, output in result {
    let factor = self.factors[world]
    for block in self.plan.blocks {
      let start = block.start
      let size = block.size
      let address = self.plan.factor_adr[start]
      if address == -2 {
        for i in 0..<size {
          output[start + i] *= self.inverse_diagonal[world][start + i]
        }
      } else {
        for i in 0..<size {
          let mut value = output[start + i]
          for k in 0..<i {
            value -= factor[address + k * size + i] * output[start + k]
          }
          output[start + i] = value / factor[address + i * size + i]
        }
        for step in 0..<size {
          let i = size - 1 - step
          let mut value = output[start + i]
          for k in (i + 1)..<size {
            value -= factor[address + i * size + k] * output[start + k]
          }
          output[start + i] = value / factor[address + i * size + i]
        }
      }
    }
    guard output.all(finite) else {
      raise Invalid("small-block triangular solve overflow")
    }
  }
  result
}

///|
pub fn BlockFactor::qld(self : BlockFactor) -> Array[Array[Double]] {
  rows_copy(self.factors)
}

///|
pub fn BlockFactor::inverse_diagonal(
  self : BlockFactor,
) -> Array[Array[Double]] {
  rows_copy(self.inverse_diagonal)
}

///|
pub fn BlockFactor::data(self : BlockFactor) -> Json {
  {
    "qLD": Json(self.factors),
    "qLDiagInv": Json(self.inverse_diagonal),
    "qLD_block_total": Json(self.plan.total),
    "qLD_block_adr": Json(self.plan.factor_adr),
    "blocks": Json(self.plan.blocks),
    "storage": "independent-small-packed-upper-blocks",
    "factorization": "compact-reciprocal-or-U-transpose-U",
  }
}
