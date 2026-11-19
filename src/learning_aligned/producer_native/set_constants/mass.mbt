///|
struct Jacobian {
  linear : Array[@geometry.Vec3]
  angular : Array[@geometry.Vec3]
  dynamic : Bool
}

///|
/// Geometric Jacobian at the actual body's COM, using only ancestral DOFs.
fn body_jacobian(
  model : RigidModel,
  layout : ModelLayout,
  state : Kinematics,
  target : Int32,
) -> Jacobian {
  let linear = Array::make(layout.nv, zero())
  let angular = Array::make(layout.nv, zero())
  let mut bodyid = target
  let mut dynamic = false
  while bodyid > 0 {
    let body = model.bodies[bodyid]
    if body.joint is Some(joint) {
      dynamic = true
      let count = if joint.kind == "free" { 6 } else { 1 }
      for dof in joint.dof_adr..<(joint.dof_adr + count) {
        if state.dof_rotational[dof] {
          angular[dof] = state.dof_axis[dof]
          linear[dof] = state.dof_axis[dof].cross(
            state.com[target].sub(state.dof_origin[dof]),
          )
        } else {
          linear[dof] = state.dof_axis[dof]
        }
      }
    }
    bodyid = body.parent
  }
  { linear, angular, dynamic, }
}

///|
/// Actual dense reference mass assembly from rigid-body kinetic energy:
/// Σ(m JvᵀJv + Jωᵀ I_world Jω) plus authored armature. This computes the same
/// generalized inertia for this explicit subset, without copying guessed CSR
/// layouts or claiming to execute MJWarp's CRB/packed-tree implementation.
fn mass_matrix(
  model : RigidModel,
  layout : ModelLayout,
  state : Kinematics,
  jacobians : Array[Jacobian],
) -> Array[Array[Double]] raise SetConstantsError {
  let mass = Array::makei(layout.nv, _ => Array::make(layout.nv, 0.0))
  for dof in 0..<layout.nv {
    mass[dof][dof] = model.armature[dof]
  }
  for bodyid in 1..<model.bodies.length() {
    let jac = jacobians[bodyid]
    let inertia = state.world_inertia[bodyid]
    let weighted = jac.angular.map(fn(axis) { inertia.mul_vec3(axis) })
    for i in 0..<layout.nv {
      for j in 0..<=i {
        let value = model.bodies[bodyid].mass * jac.linear[i].dot(jac.linear[j]) +
          jac.angular[i].dot(weighted[j])
        guard finite(value) && finite(mass[i][j] + value) else {
          raise Invalid("generalized mass assembly overflow")
        }
        mass[i][j] += value
        if i != j {
          mass[j][i] = mass[i][j]
        }
      }
    }
  }
  mass
}

///|
fn quadratic(
  row : Array[Double],
  inverse : Array[Array[Double]],
) -> Double raise SetConstantsError {
  let mut result = 0.0
  for i in 0..<row.length() {
    for j in 0..<row.length() {
      result += row[i] * inverse[i][j] * row[j]
    }
  }
  guard finite(result) && result >= -1.0e-10 else {
    raise Invalid("inverse inertia quadratic form is negative/nonfinite")
  }
  if result < 0.0 {
    0.0
  } else {
    result
  }
}

///|
fn component(value : @geometry.Vec3, index : Int32) -> Double {
  match index {
    0 => value.x
    1 => value.y
    _ => value.z
  }
}

///|
/// Body mean diagonal J inv(M) Jᵀ, preserving MuJoCo's static-body zero and
/// cross-component fallback at mjMINVAL=1e-15. Translation precedes rotation.
fn body_inverse_weight(
  jacobian : Jacobian,
  inverse : Array[Array[Double]],
) -> BodyInverseWeight raise SetConstantsError {
  if !jacobian.dynamic {
    return { translation: 0.0, rotation: 0.0, }
  }
  let diag : Array[Double] = []
  for row in 0..<6 {
    let vectors = if row < 3 { jacobian.linear } else { jacobian.angular }
    let axis = row % 3
    diag.push(quadratic(vectors.map(value => component(value, axis)), inverse))
  }
  let mut translation = (diag[0] + diag[1] + diag[2]) / 3.0
  let mut rotation = (diag[3] + diag[4] + diag[5]) / 3.0
  if translation < 1.0e-15 && rotation > 1.0e-15 {
    translation = rotation
  } else if rotation < 1.0e-15 && translation > 1.0e-15 {
    rotation = translation
  }
  guard finite(translation) && finite(rotation) else {
    raise Invalid("body inverse-weight averaging overflow")
  }
  { translation, rotation, }
}

///|
fn dof_inverse_weights(
  model : RigidModel,
  inverse : Array[Array[Double]],
) -> Array[Double] raise SetConstantsError {
  let result = Array::makei(inverse.length(), i => inverse[i][i])
  guard result.all(value => finite(value) && value > 0.0) else {
    raise Invalid("mass matrix inverse has a nonpositive/nonfinite diagonal")
  }
  for body in model.bodies {
    if body.joint is Some(joint) {
      if joint.kind == "free" {
        let start = joint.dof_adr
        let translation = (
            result[start] + result[start + 1] + result[start + 2]
          ) /
          3.0
        let rotation = (
            result[start + 3] + result[start + 4] + result[start + 5]
          ) /
          3.0
        guard finite(translation) && finite(rotation) else {
          raise Invalid("free joint inverse-weight averaging overflow")
        }
        for axis in 0..<3 {
          result[start + axis] = translation
          result[start + 3 + axis] = rotation
        }
      }
    }
  }
  result
}

///|
/// Evaluate the supported rigid reference at qpos0. The corresponding host
/// solve is real moonnum checked LU; it is not MuJoCo-Warp factor_m/solve_m.
pub fn rigid_reference(
  model : RigidModel,
  qpos0 : Array[Double],
) -> WorldConstants raise {
  let layout = validate_model(model)
  let state = kinematics(model, layout, qpos0, qpos0)
  let jacobians = Array::makei(model.bodies.length(), body => {
    body_jacobian(model, layout, state, body)
  })
  let mass = mass_matrix(model, layout, state, jacobians)
  let inverse = if layout.nv == 0 {
    []
  } else {
    @linalg.solve(
      mass,
      Array::makei(layout.nv, i => {
        Array::makei(layout.nv, j => if i == j { 1.0 } else { 0.0 })
      }),
    )
  }
  let dof_invweight = dof_inverse_weights(model, inverse)
  let body_invweight = jacobians.map(fn(jac) {
    body_inverse_weight(jac, inverse)
  })
  let parents = model.bodies.map(body => body.parent)
  let masses = @constants.subtree_masses({
      parent: parents,
      body_mass: [model.bodies.map(body => body.mass)],
      output_worlds: 1,
    })[0]
  let weighted = Array::makei(model.bodies.length(), body => {
    state.com[body].scale(model.bodies[body].mass)
  })
  for offset in 0..<(model.bodies.length() - 1) {
    let body = model.bodies.length() - 1 - offset
    weighted[parents[body]] = weighted[parents[body]].add(weighted[body])
    guard vector_ok(weighted[parents[body]]) else {
      raise Invalid("subtree center-of-mass accumulation overflow")
    }
  }
  let centers = Array::makei(model.bodies.length(), body => {
    if masses[body] == 0.0 {
      weighted[body]
    } else {
      @geometry.vec3(
        weighted[body].x / masses[body],
        weighted[body].y / masses[body],
        weighted[body].z / masses[body],
      )
    }
  })
  guard centers.all(vector_ok) else {
    raise Invalid("subtree center-of-mass division overflow")
  }
  let composite = Array::makei(model.bodies.length(), body => {
    add_basis(
      state.world_inertia[body],
      parallel_axis(model.bodies[body].mass, state.com[body].sub(centers[body])),
    )
  })
  guard composite.all(value => basis_values(value).all(finite)) else {
    raise Invalid("body-to-subtree parallel-axis inertia overflow")
  }
  for offset in 0..<(model.bodies.length() - 1) {
    let body = model.bodies.length() - 1 - offset
    let parent = parents[body]
    let translated = add_basis(
      composite[body],
      parallel_axis(masses[body], centers[body].sub(centers[parent])),
    )
    composite[parent] = add_basis(composite[parent], translated)
    guard basis_values(composite[parent]).all(finite) else {
      raise Invalid("subtree composite inertia overflow")
    }
  }
  let packed : Array[Double] = []
  let row_nnz : Array[Int32] = []
  let row_adr : Array[Int32] = []
  for row in 0..<layout.nv {
    row_adr.push(packed.length())
    row_nnz.push(row + 1)
    for col in 0..<=row {
      packed.push(mass[row][col])
    }
  }
  let mean = @constants.mean_inertia_from_mass_matrix({
      nv: layout.nv,
      row_nnz,
      row_adr,
      matrix: [packed],
    })[0]
  {
    body_pose: state.pose,
    body_com: state.com,
    body_world_inertia: state.world_inertia,
    subtree_mass: masses,
    subtree_com: centers,
    subtree_inertia_about_com: composite,
    mass_matrix: mass,
    inverse_mass_matrix: inverse,
    dof_invweight0: dof_invweight,
    body_invweight0: body_invweight,
    mean_inertia: mean,
  }
}
