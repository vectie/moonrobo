///|
fn upper_factor(
  values : Array[Double],
  output : Array[Double],
  address : Int32,
  size : Int32,
  zero_lower : Bool,
  world : Int32,
  start : Int32,
) -> Unit raise FactorizationError {
  if zero_lower {
    for row in 0..<size {
      for col in 0..<row {
        output[address + row * size + col] = 0.0
      }
    }
  }
  for i in 0..<size {
    let mut value = values[i * size + i]
    for k in 0..<i {
      let v = output[address + k * size + i]
      value -= v * v
    }
    pivot(value, world, start + i)
    let diagonal = value.sqrt()
    pivot(diagonal, world, start + i)
    output[address + i * size + i] = diagonal
    let inverse = 1.0 / diagonal
    pivot(inverse, world, start + i)
    for j in (i + 1)..<size {
      let mut value = values[i * size + j]
      for k in 0..<i {
        value -= output[address + k * size + i] * output[address + k * size + j]
      }
      let result = value * inverse
      guard finite(result) else {
        raise Invalid("mixed upper Cholesky update overflow")
      }
      output[address + i * size + j] = result
    }
  }
}

///|
/// Actual mixed factor storage: dense block prefix followed, when sparse DOFs
/// exist, by a complete nC CSR copy. Gather blocks densify only their <=64 DOFs.
pub fn factor_mixed(
  request : MixedRequest,
) -> MixedFactor raise FactorizationError {
  let plan = mixed_plan(request.layout)
  let worlds = request.matrix.length()
  options(worlds, request.regularization, request.skip_worlds)
  check_rows(request.matrix, worlds, plan.col.length(), "matrix")
  let width = plan.total + (if plan.has_sparse { plan.col.length() } else { 0 })
  let factors = match request.factor_seed {
    Some(seed) => {
      check_rows(seed, worlds, width, "factor_seed")
      rows_copy(seed)
    }
    None => Array::makei(worlds, _ => Array::make(width, 0.0))
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
      match block.kind {
        Compact =>
          for i in block.start..<(block.start + block.size) {
            let diagonal = matrix[plan.adr[i]]
            pivot(diagonal, world, i)
            let inverse = 1.0 / diagonal
            pivot(inverse, world, i)
            inverse_diagonal[world][i] = inverse
          }
        Scalar | Gather => {
          let values = Array::makei(block.size * block.size, slot => {
            let index = if block.kind == Gather {
              block.elemid[slot]
            } else {
              csr_slot(
                plan.adr,
                plan.nnz,
                plan.col,
                block.start + slot / block.size,
                block.start + slot % block.size,
              )
            }
            if index == plan.col.length() {
              0.0
            } else {
              matrix[index]
            }
          })
          upper_factor(
            values,
            factor,
            address,
            block.size,
            block.kind == Gather,
            world,
            block.start,
          )
        }
        Sparse => ()
      }
    }
    if plan.has_sparse {
      // The source copies the ENTIRE M into the sparse tail, including CSR
      // entries belonging to dense/compact blocks; only sparse updates change it.
      for i in 0..<matrix.length() {
        factor[plan.total + i] = matrix[i]
      }
      for step in 0..<plan.levels.length() {
        let before = factor.copy()
        for update in plan.levels[plan.levels.length() - 1 - step] {
          let diagonal = plan.total +
            plan.adr[update.k] +
            plan.nnz[update.k] -
            1
          pivot(before[diagonal], world, update.k)
          let multiplier = before[plan.total + update.madr_ki] /
            before[diagonal]
          guard finite(multiplier) else {
            raise Invalid("mixed sparse multiplier overflow")
          }
          for j in 0..<plan.nnz[update.i] {
            let target = plan.total + plan.adr[update.i] + j
            let result = factor[target] -
              before[plan.total + plan.adr[update.k] + j] * multiplier
            guard finite(result) else {
              raise Invalid("mixed sparse accumulation overflow")
            }
            factor[target] = result
          }
          factor[plan.total + update.madr_ki] = multiplier
        }
      }
      // _qLDiag_div runs over ALL nv whenever the sparse tail exists. This
      // overwrites earlier block D values too, even though full block solves
      // ignore D; preserving that visible storage detail matters for diff tests.
      for i in 0..<plan.nnz.length() {
        let diagonal = factor[plan.total + plan.adr[i] + plan.nnz[i] - 1]
        pivot(diagonal, world, i)
        let inverse = 1.0 / diagonal
        pivot(inverse, world, i)
        inverse_diagonal[world][i] = inverse
      }
    }
  }
  { plan, factors, inverse_diagonal, }
}

///|
pub fn MixedFactor::solve(
  self : MixedFactor,
  rhs : Array[Array[Double]],
) -> Array[Array[Double]] raise FactorizationError {
  let plan = self.plan
  check_rows(rhs, self.factors.length(), plan.nnz.length(), "rhs")
  let result = rows_copy(rhs)
  for world, output in result {
    let factor = self.factors[world]
    for block in plan.blocks {
      match block.kind {
        Sparse => ()
        Compact =>
          for i in block.start..<(block.start + block.size) {
            output[i] *= self.inverse_diagonal[world][i]
          }
        Scalar | Gather => {
          let start = block.start
          let size = block.size
          let address = plan.factor_adr[start]
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
    }
    if plan.has_sparse {
      for step in 0..<plan.levels.length() {
        let before = output.copy()
        for update in plan.levels[plan.levels.length() - 1 - step] {
          output[update.i] -= factor[plan.total + update.madr_ki] *
            before[update.k]
        }
      }
      for i in 0..<output.length() {
        if plan.factor_adr[i] == -1 {
          output[i] *= self.inverse_diagonal[world][i]
        }
      }
      for updates in plan.levels {
        let before = output.copy()
        for update in updates {
          output[update.k] -= factor[plan.total + update.madr_ki] *
            before[update.i]
        }
      }
    }
    guard output.all(finite) else {
      raise Invalid("mixed triangular solve overflow")
    }
  }
  result
}

///|
pub fn MixedFactor::qld(self : MixedFactor) -> Array[Array[Double]] {
  rows_copy(self.factors)
}

///|
pub fn MixedFactor::inverse_diagonal(
  self : MixedFactor,
) -> Array[Array[Double]] {
  rows_copy(self.inverse_diagonal)
}

///|
pub fn MixedFactor::data(self : MixedFactor) -> Json {
  let blocks = self.plan.blocks.map(block => {
    let kind = match block.kind {
      Compact => "compact"
      Scalar => "scalar-upper"
      Gather => "gather-upper"
      Sparse => "sparse-LDL"
    }
    {
      "start": Json(block.start),
      "size": Json(block.size),
      "kind": Json(kind),
      "elemid": Json(block.elemid),
      "factor_adr": Json(self.plan.factor_adr[block.start]),
    }
  })
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
    "qLD_block_total": Json(self.plan.total),
    "qLD_block_adr": Json(self.plan.factor_adr),
    "sparse_tail_length": Json(
      if self.plan.has_sparse {
        self.plan.col.length()
      } else {
        0
      },
    ),
    "M_rownnz": Json(self.plan.nnz),
    "M_rowadr": Json(self.plan.adr),
    "M_colind": Json(self.plan.col),
    "dof_parentid": Json(self.plan.parent),
    "blocks": Json(blocks),
    "qLD_updates": Json(self.plan.levels),
    "tree_dofadr": Json(self.plan.tree_adr),
    "tree_dofnum": Json(self.plan.tree_num),
    "qLD_all_updates": Json(if updates.is_empty() { [dummy] } else { updates }),
    "qLD_level_offsets": Json(offsets),
    "storage": "mixed-dense-prefix-plus-complete-CSR-tail",
    "gpu_tile_executed": false,
  }
}
