///|
/// Canonical contiguous snapshots are copied from the actual views. This
/// validates index/domain bytes only; it never evaluates a numeric algorithm.
fn int_at(bytes : Bytes, index : Int32) -> Int32 raise {
  guard index >= 0 && index < bytes.length() / 4 else {
    fail("Newton metadata integer read exceeds snapshot")
  }
  let i = index * 4
  (bytes[i].to_uint() |
  (bytes[i + 1].to_uint() << 8) |
  (bytes[i + 2].to_uint() << 16) |
  (bytes[i + 3].to_uint() << 24)).reinterpret_as_int()
}

///|
fn float_at(bytes : Bytes, index : Int32) -> Float raise {
  Float::reinterpret_from_int(int_at(bytes, index))
}

///|
fn input_dtype(name : String) -> String {
  if [
      "ne", "nf", "nefc", "nacon", "efc_type", "efc_id", "M_rowadr", "M_rownnz",
      "M_colind", "efc_J_rownnz", "efc_J_rowadr", "efc_J_colind", "contact_dim",
      "contact_worldid", "contact_efc_address",
    ].contains(name) {
    "int32"
  } else if name == "contact_friction" {
    "vec5f"
  } else {
    "float32"
  }
}

///|
pub fn validate_metadata(r : Request, data : Map[String, Bytes]) -> Unit raise {
  validate(r)
  for name in immutable_parameters(r) {
    guard data.get(name) is Some(bytes) else {
      fail("missing actual Newton input snapshot: " + name)
    }
    let shape = expected_shape(r, name)
    let components = if name == "contact_friction" { 5 } else { 1 }
    let mut count = components
    for n in shape {
      guard n == 0 || count <= 2147483647 / n else {
        fail("Newton input shape overflow")
      }
      count *= n
    }
    let broadcast = [
      "opt_tolerance", "opt_ls_tolerance", "stat_meaninertia", "opt_impratio_invsqrt",
    ].contains(name)
    guard count <= 2147483647 / 4 &&
      (bytes.length() == count * 4 || (broadcast && bytes.length() == 4)) else {
      fail("actual Newton snapshot length differs: " + name)
    }
    if input_dtype(name) != "int32" {
      for i in 0..<(bytes.length() / 4) {
        let v = float_at(bytes, i)
        guard !v.is_nan() && !v.is_inf() else {
          fail("nonfinite authored Newton input")
        }
        if [
            "efc_D", "efc_frictionloss", "opt_tolerance", "opt_ls_tolerance", "contact_friction",
          ].contains(name) {
          guard v >= 0.0F else {
            fail("negative authored Newton diagonal/friction/tolerance")
          }
        }
        if ["stat_meaninertia", "opt_impratio_invsqrt"].contains(name) {
          guard v > 0.0F else { fail("nonpositive Newton inertia/impratio") }
        }
      }
    }
  }
  if r.njmax == 0 || r.nv == 0 {
    return
  }
  let nacon = int_at(data["nacon"], 0)
  guard nacon >= 0 && nacon <= r.ncon else {
    fail("actual nacon exceeds authored contact buffers")
  }
  if r.mass_layout == "csr" {
    let mut prefix = 0
    for row in 0..<r.nv {
      let adr = int_at(data["M_rowadr"], row)
      let nnz = int_at(data["M_rownnz"], row)
      guard adr == prefix && nnz >= 1 && nnz <= r.mass_nnz - prefix else {
        fail("mass CSR requires exact compact row prefixes")
      }
      let mut previous = -1
      for k in adr..<(adr + nnz) {
        let col = int_at(data["M_colind"], k)
        guard col > previous && col <= row else {
          fail("mass lower CSR columns must be unique sorted and bounded")
        }
        previous = col
      }
      guard previous == row else {
        fail("mass CSR diagonal must be row's last element")
      }
      prefix += nnz
    }
    guard prefix == r.mass_nnz else {
      fail("mass CSR does not consume actual coefficient bytes")
    }
  }
  for world in 0..<r.nworld {
    let ne = int_at(data["ne"], world)
    let nf = int_at(data["nf"], world)
    let count = int_at(data["nefc"], world)
    guard ne >= 0 &&
      nf >= 0 &&
      count >= 0 &&
      count <= r.njmax &&
      ne <= count &&
      nf <= count - ne else {
      fail("actual equality/friction/constraint counts invalid")
    }
    for row in 0..<count {
      let idx = world * r.njmax + row
      if r.jacobian_layout == "csr" {
        let adr = int_at(data["efc_J_rowadr"], idx)
        let nnz = int_at(data["efc_J_rownnz"], idx)
        guard adr >= 0 &&
          nnz >= 0 &&
          adr <= r.jacobian_capacity &&
          nnz <= r.jacobian_capacity - adr else {
          fail("actual Jacobian CSR row exceeds authored storage")
        }
        for k in adr..<(adr + nnz) {
          let col = int_at(
            data["efc_J_colind"],
            world * r.jacobian_capacity + k,
          )
          guard col >= 0 && col < r.nv else {
            fail("actual Jacobian column exceeds DOFs")
          }
        }
      }
      let kind = int_at(data["efc_type"], idx)
      guard kind >= 0 && kind <= 7 else {
        fail("unknown actual constraint type")
      }
      if kind == 7 {
        guard r.cone == "elliptic" && row >= ne + nf else {
          fail("elliptic row outside supported cone partition")
        }
        let con = int_at(data["efc_id"], idx)
        guard con >= 0 &&
          con < nacon &&
          int_at(data["contact_worldid"], con) == world else {
          fail("elliptic row/contact mapping invalid")
        }
        let dim = int_at(data["contact_dim"], con)
        guard [3, 4, 6].contains(dim) else {
          fail("elliptic contact dimension must be 3,4,6")
        }
        let seen : Map[Int32, Unit] = {}
        for axis in 0..<dim {
          let linked = int_at(data["contact_efc_address"], con * 6 + axis)
          guard linked >= ne + nf &&
            linked < count &&
            !seen.contains(linked) &&
            int_at(data["efc_type"], world * r.njmax + linked) == 7 &&
            int_at(data["efc_id"], world * r.njmax + linked) == con else {
            fail(
              "elliptic contact row addresses must form an actual unique group",
            )
          }
          seen[linked] = ()
        }
        guard seen.contains(row) else {
          fail("elliptic row absent from its contact")
        }
        let f0 = float_at(data["contact_friction"], con * 5)
        let imp = data["opt_impratio_invsqrt"]
        let mu = f0 * float_at(imp, if imp.length() == 4 { 0 } else { world })
        let denom = mu * mu * (1.0F + mu * mu)
        guard mu > 0.0F && !mu.is_inf() && denom > 0.0F && !denom.is_inf() else {
          fail("elliptic metric denominator not finite positive in float32")
        }
      }
    }
  }
}
