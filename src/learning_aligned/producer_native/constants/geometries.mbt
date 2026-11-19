///|
/// Newton's positive-format stiffness/damping conversion, with d(width)=d(r)
/// equal to one as used by update_geom_properties_kernel. Raw MuJoCo solref is
/// handled separately and may contain its valid negative direct-format values.
pub fn material_solref(
  stiffness : Double,
  damping : Double,
) -> Array[Double] raise ConstantsError {
  guard finite(stiffness) && finite(damping) else {
    raise Invalid("material stiffness/damping must be finite")
  }
  if stiffness > 0.0 && damping > 0.0 {
    let timeconst = 2.0 / damping
    let dampratio = damping / 2.0 * (1.0 / stiffness).sqrt()
    guard finite(timeconst) && finite(dampratio) && timeconst > 0.0 else {
      raise Invalid("material solref conversion overflow or underflow")
    }
    [timeconst, dampratio]
  } else {
    [0.02, 1.0]
  }
}

///|
fn GeomConstant::validate(self : GeomConstant) -> Unit raise ConstantsError {
  check_vector(self.friction, "geom friction")
  check_vector(self.size, "geom size")
  check_vector(self.position, "geom position")
  check_tuple(self.solref, 2, "geom solref")
  check_tuple(self.solimp, 5, "geom solimp")
  guard quaternion_finite(self.orientation) &&
    finite(self.solmix) &&
    finite(self.margin) &&
    finite(self.gap) else {
    raise Invalid("geom orientation/material constants are nonfinite")
  }
}

///|
/// Real analytic-shape material/size/pose updates. Mesh and heightfield local
/// corrections are refused; geom_rbound is not recomputed, matching upstream.
pub fn update_geometries(
  request : GeomUpdate,
) -> Array[Array[GeomConstant]] raise ConstantsError {
  guard !request.mapping.is_empty() &&
    request.mapping.length() == request.existing.length() else {
    raise Invalid("geom mapping world cardinality differs from output")
  }
  let width = request.mapping[0].length()
  guard request.mapping.all(row => row.length() == width) &&
    request.existing.all(row => row.length() == width) else {
    raise Invalid("geom mapping/output rows have inconsistent cardinality")
  }
  let rotations : Array[Quaternion] = []
  let references : Array[Array[Double]] = []
  for shape in request.shapes {
    guard ["plane", "sphere", "capsule", "ellipsoid", "cylinder", "box"].contains(
      shape.kind,
    ) else {
      raise Unsupported(
        "mesh/heightfield/SDF/flex geom transform/constants require their actual upstream adapter",
      )
    }
    check_vector(shape.friction, "shape friction")
    check_vector(shape.size, "shape size")
    check_vector(shape.pose.translation, "shape position")
    guard shape.friction.x >= 0.0 &&
      shape.friction.y >= 0.0 &&
      shape.friction.z >= 0.0 &&
      shape.size.x >= 0.0 &&
      shape.size.y >= 0.0 &&
      shape.size.z >= 0.0 &&
      finite(shape.margin) &&
      finite(shape.gap) else {
      raise Invalid("shape friction/size/margin/gap is invalid")
    }
    guard ["raw", "force-space", "mjcf-default"].contains(shape.solref_mode) else {
      raise Unsupported("unknown shape solref mode")
    }
    let solref = if shape.solref_mode == "raw" {
      guard shape.raw_solref is Some(raw) else {
        raise Invalid("raw solref mode requires actual authored values")
      }
      check_tuple(raw, 2, "raw shape solref")
      raw.copy()
    } else {
      material_solref(shape.stiffness, shape.damping)
    }
    if shape.solimp is Some(value) {
      check_tuple(value, 5, "shape solimp")
    }
    if shape.solmix is Some(value) {
      guard finite(value) else { raise Invalid("shape solmix is nonfinite") }
    }
    rotations.push(rotation_quaternion(shape.pose.basis))
    references.push(solref)
  }
  request.mapping.mapi(fn(world, row) {
    row.mapi(fn(geom, index) {
      let old = request.existing[world][geom]
      old.validate()
      guard index >= -1 && index < request.shapes.length() else {
        raise Invalid("geom mapping index outside actual Newton shapes")
      }
      if index == -1 {
        { ..old, solref: old.solref.copy(), solimp: old.solimp.copy(), }
      } else {
        let shape = request.shapes[index]
        {
          friction: shape.friction,
          solref: references[index].copy(),
          size: shape.size,
          position: shape.pose.translation,
          orientation: rotations[index],
          solimp: match shape.solimp {
            Some(value) => value.copy()
            None => old.solimp.copy()
          },
          solmix: match shape.solmix {
            Some(value) => value
            None => old.solmix
          },
          margin: if request.zero_native_ccd_margins {
            0.0
          } else {
            shape.margin
          },
          gap: shape.gap,
        }
      }
    })
  })
}
