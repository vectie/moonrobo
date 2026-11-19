///|
fn validate_model(model : RigidModel) -> ModelLayout raise {
  let count = model.bodies.length()
  let nv = model.armature.length()
  guard count > 0 &&
    count <= 256 &&
    nv <= 96 &&
    model.armature.all(value => finite(value) && value >= 0.0) else {
    raise Invalid(
      "host reference subset requires 1..256 bodies, at most 96 DOFs and finite physical armature",
    )
  }
  let used_dof = Array::make(nv, false)
  let qpos_slots : Array[Int32] = []
  let physical_inertia : Array[@geometry.Basis3] = []
  let mut nq = 0
  let mut free_count = 0
  for index, body in model.bodies {
    guard finite(body.mass) &&
      body.mass >= 0.0 &&
      vector_ok(body.com) &&
      vector_ok(body.pose.translation) else {
      raise Invalid("body mass/COM/authored translation is invalid")
    }
    ignore(@constants.rotation_quaternion(body.pose.basis))
    let principal = @constants.principal_inertia(body.inertia)
    let inertia = principal.axes
      .mul_basis3(diagonal(principal.moments))
      .mul_basis3(transpose(principal.axes))
    physical_inertia.push(inertia)
    if index == 0 {
      guard body.parent == 0 &&
        body.joint is None &&
        body.mass == 0.0 &&
        body.com == zero() &&
        basis_values(body.inertia).all(value => value == 0.0) &&
        body.pose.translation == zero() &&
        body.pose.basis == @geometry.identity_basis3() else {
        raise Invalid(
          "world body zero must be fixed, massless and identity-authored",
        )
      }
    } else {
      guard body.parent >= 0 && body.parent < index else {
        raise Invalid(
          "body tree must use actual MuJoCo parent-before-child indexing",
        )
      }
    }
    if body.joint is Some(joint) {
      guard vector_ok(joint.anchor) && vector_ok(joint.axis) else {
        raise Invalid("joint anchor/axis is nonfinite")
      }
      let (width, dofs) = match joint.kind {
        "hinge" | "slide" => {
          guard (joint.axis.length_squared() - 1.0).abs() <= 1.0e-10 else {
            raise Invalid(
              "hinge/slide axis must be the actual normalized compiled axis",
            )
          }
          (1, 1)
        }
        "free" => {
          guard body.parent == 0 else {
            raise Unsupported("free joint must be on a root body")
          }
          free_count += 1
          guard free_count <= 1 else {
            raise Unsupported(
              "host subset currently supports at most one free root",
            )
          }
          (7, 6)
        }
        _ =>
          raise Unsupported(
            "ball, multi-joint bodies and unknown joint kinds need their real coordinate adapter",
          )
      }
      guard joint.qpos_adr >= 0 &&
        joint.qpos_adr <= 103 - width &&
        joint.dof_adr >= 0 &&
        joint.dof_adr <= nv - dofs else {
        raise Invalid("joint coordinate/DOF range is invalid")
      }
      for slot in joint.qpos_adr..<(joint.qpos_adr + width) {
        guard !qpos_slots.contains(slot) else {
          raise Invalid("joint coordinate ranges overlap")
        }
        qpos_slots.push(slot)
      }
      nq = math_max(nq, joint.qpos_adr + width)
      for slot in joint.dof_adr..<(joint.dof_adr + dofs) {
        guard !used_dof[slot] else { raise Invalid("joint DOF ranges overlap") }
        used_dof[slot] = true
      }
    }
  }
  guard qpos_slots.length() == nq && used_dof.all(value => value) else {
    raise Invalid("unclassified joint coordinate or DOF gaps")
  }
  { nq, nv, physical_inertia, }
}

///|
fn math_max(a : Int32, b : Int32) -> Int32 {
  if a > b {
    a
  } else {
    b
  }
}

///|
fn free_basis(
  qpos : Array[Double],
  start : Int32,
) -> @geometry.Basis3 raise SetConstantsError {
  let w = qpos[start]
  let x = qpos[start + 1]
  let y = qpos[start + 2]
  let z = qpos[start + 3]
  let norm = (w * w + x * x + y * y + z * z).sqrt()
  guard finite(norm) && norm > 0.0 else {
    raise Invalid("free-root qpos0 quaternion must have finite nonzero norm")
  }
  let w = w / norm
  let x = x / norm
  let y = y / norm
  let z = z / norm
  {
    xx: 1.0 - 2.0 * (y * y + z * z),
    xy: 2.0 * (x * y - z * w),
    xz: 2.0 * (x * z + y * w),
    yx: 2.0 * (x * y + z * w),
    yy: 1.0 - 2.0 * (x * x + z * z),
    yz: 2.0 * (y * z - x * w),
    zx: 2.0 * (x * z - y * w),
    zy: 2.0 * (y * z + x * w),
    zz: 1.0 - 2.0 * (x * x + y * y),
  }
}

///|
/// Actual rigid FK around compiled joint anchors. Coordinates and reference
/// have distinct roles so this also supports testing nonzero hinge/slide deltas;
/// set_const reference evaluation supplies qpos0 for both, as upstream does.
fn kinematics(
  model : RigidModel,
  layout : ModelLayout,
  qpos : Array[Double],
  reference : Array[Double],
) -> Kinematics raise {
  guard qpos.length() == layout.nq &&
    reference.length() == layout.nq &&
    qpos.all(finite) &&
    reference.all(finite) else {
    raise Invalid(
      "coordinate/reference cardinality or finite values differ from compiled layout",
    )
  }
  let pose : Array[@geometry.Transform3] = []
  let com : Array[@geometry.Vec3] = []
  let world_inertia : Array[@geometry.Basis3] = []
  let dof_axis = Array::make(layout.nv, zero())
  let dof_origin = Array::make(layout.nv, zero())
  let dof_rotational = Array::make(layout.nv, false)
  for bodyid, body in model.bodies {
    let mut current = if bodyid == 0 {
      body.pose
    } else {
      pose[body.parent].compose(body.pose)
    }
    if body.joint is Some(joint) {
      let start = joint.dof_adr
      if joint.kind == "free" {
        let q = joint.qpos_adr
        current = @geometry.transform3(
          free_basis(qpos, q + 3),
          @geometry.vec3(qpos[q], qpos[q + 1], qpos[q + 2]),
        )
        let unit = [
          @geometry.vec3(1.0, 0.0, 0.0),
          @geometry.vec3(0.0, 1.0, 0.0),
          @geometry.vec3(0.0, 0.0, 1.0),
        ]
        for axis in 0..<3 {
          dof_axis[start + axis] = unit[axis]
          dof_axis[start + 3 + axis] = current.basis.mul_vec3(unit[axis])
          dof_origin[start + 3 + axis] = current.translation
          dof_rotational[start + 3 + axis] = true
        }
      } else {
        let axis = current.basis.mul_vec3(joint.axis)
        let anchor = current.transform_point(joint.anchor)
        let delta = qpos[joint.qpos_adr] - reference[joint.qpos_adr]
        guard finite(delta) else {
          raise Invalid("joint reference delta overflow")
        }
        dof_axis[start] = axis
        dof_origin[start] = anchor
        if joint.kind == "slide" {
          current = {
            ..current,
            translation: current.translation.add(axis.scale(delta)),
          }
        } else {
          let rotated = current.basis.mul_basis3(
            @geometry.axis_angle_basis3(joint.axis, delta),
          )
          current = @geometry.transform3(
            rotated,
            anchor.sub(rotated.mul_vec3(joint.anchor)),
          )
          dof_rotational[start] = true
        }
      }
    }
    guard vector_ok(current.translation) &&
      basis_values(current.basis).all(finite) else {
      raise Invalid("rigid-body forward kinematics overflow")
    }
    let point = current.transform_point(body.com)
    let inertia = current.basis
      .mul_basis3(layout.physical_inertia[bodyid])
      .mul_basis3(transpose(current.basis))
    guard vector_ok(point) && basis_values(inertia).all(finite) else {
      raise Invalid("body inertial frame overflow")
    }
    pose.push(current)
    com.push(point)
    world_inertia.push(inertia)
  }
  { pose, com, world_inertia, dof_axis, dof_origin, dof_rotational, }
}
