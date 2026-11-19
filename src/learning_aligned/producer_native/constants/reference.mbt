///|
/// Actual fixed mass accumulation, corresponding to MJWarp set_const_fixed.
/// Input rows may be one shared world or one row per output world. A validated
/// bottom-up body order replaces parallel depth buckets, so floating summation
/// order can differ from Warp atomic_add and remains subject to later parity.
pub fn subtree_masses(
  request : SubtreeRequest,
) -> Array[Array[Double]] raise ConstantsError {
  let n = request.parent.length()
  guard n > 0 &&
    request.output_worlds > 0 &&
    request.parent[0] == 0 &&
    (
      request.body_mass.length() == 1 ||
      request.body_mass.length() == request.output_worlds
    ) &&
    request.body_mass.all(row => {
      row.length() == n && row.all(value => finite(value) && value >= 0.0)
    }) else {
    raise Invalid(
      "subtree mass requires one rooted body tree and shared/per-world finite nonnegative masses",
    )
  }
  let children = Array::make(n, 0)
  for body in 1..<n {
    let parent = request.parent[body]
    guard parent >= 0 && parent < n && parent != body else {
      raise Invalid("body parent is invalid or self-referential")
    }
    children[parent] += 1
  }
  let order : Array[Int32] = []
  for body in 0..<n {
    if children[body] == 0 {
      order.push(body)
    }
  }
  let mut cursor = 0
  while cursor < order.length() {
    let body = order[cursor]
    cursor += 1
    if body != 0 {
      let parent = request.parent[body]
      children[parent] -= 1
      if children[parent] == 0 {
        order.push(parent)
      }
    }
  }
  guard order.length() == n && order[n - 1] == 0 else {
    raise Invalid("body parent graph contains a cycle or disconnected root")
  }
  Array::makei(request.output_worlds, fn(world) {
    let row = request.body_mass[world % request.body_mass.length()].copy()
    for body in order {
      if body != 0 {
        let parent = request.parent[body]
        row[parent] += row[body]
        guard finite(row[parent]) else {
          raise Invalid("subtree mass sum overflow")
        }
      }
    }
    row
  })
}

///|
/// Read the last entry of each real CSR mass-matrix row, exactly as the
/// pinned meaninertia kernel does. No dense/sparse-Jacobian assumption is made;
/// M uses the actual supplied inertia layout. nv=0 has MuJoCo's default 1.
pub fn mean_inertia_from_mass_matrix(
  request : MeanInertiaRequest,
) -> Array[Double] raise ConstantsError {
  guard request.nv >= 0 &&
    request.row_nnz.length() == request.nv &&
    request.row_adr.length() == request.nv &&
    !request.matrix.is_empty() &&
    request.matrix.all(row => {
      row.length() == request.matrix[0].length() && row.all(finite)
    }) else {
    raise Invalid(
      "mass-matrix CSR metadata/world cardinality/values are invalid",
    )
  }
  let diagonal : Array[Int32] = []
  let mut cursor = 0
  for row in 0..<request.nv {
    let count = request.row_nnz[row]
    let start = request.row_adr[row]
    guard count > 0 && start == cursor && start <= 2147483647 - count else {
      raise Invalid("mass-matrix CSR row offset/count is invalid or overflows")
    }
    let index = start + count - 1
    guard request.matrix.all(values => index < values.length()) else {
      raise Invalid("mass-matrix CSR diagonal lies outside an actual world row")
    }
    diagonal.push(index)
    cursor += count
  }
  guard cursor == request.matrix[0].length() else {
    raise Invalid(
      "mass-matrix CSR rows must exactly consume the compact inertia storage",
    )
  }
  request.matrix.map(fn(row) {
    if request.nv == 0 {
      1.0
    } else {
      let mut total = 0.0
      for index in diagonal {
        guard row[index] >= 0.0 else {
          raise Invalid("physical mass-matrix diagonal cannot be negative")
        }
        total += row[index]
        guard finite(total) else {
          raise Invalid("mass-matrix diagonal sum overflow")
        }
      }
      total / request.nv.to_double()
    }
  })
}

///|
/// Copy actual qpos and expand the actual model qpos0 for host pre-pass input.
/// This does not modify GPU qpos, run kinematics/CRB, or restore active caches.
pub fn reference_qpos(
  request : ReferenceRequest,
) -> ReferenceQpos raise ConstantsError {
  guard !request.qpos.is_empty() &&
    (
      request.qpos0.length() == 1 ||
      request.qpos0.length() == request.qpos.length()
    ) else {
    raise Invalid("qpos0 must have one shared row or one row per current world")
  }
  let width = request.qpos[0].length()
  guard request.qpos.all(row => row.length() == width && row.all(finite)) &&
    request.qpos0.all(row => row.length() == width && row.all(finite)) else {
    raise Invalid("qpos/qpos0 coordinate cardinality or finite values differ")
  }
  {
    saved: matrix_copy(request.qpos),
    reference: Array::makei(request.qpos.length(), fn(world) {
      request.qpos0[world % request.qpos0.length()].copy()
    }),
  }
}

///|
pub fn ReferenceQpos::saved(self : ReferenceQpos) -> Array[Array[Double]] {
  matrix_copy(self.saved)
}

///|
pub fn ReferenceQpos::reference(self : ReferenceQpos) -> Array[Array[Double]] {
  matrix_copy(self.reference)
}

///|
/// Returns host restore input bytes/values only, without touching a solver.
pub fn ReferenceQpos::restore(self : ReferenceQpos) -> Array[Array[Double]] {
  matrix_copy(self.saved)
}
