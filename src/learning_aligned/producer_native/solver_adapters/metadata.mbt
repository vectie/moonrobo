///|
/// These are the canonical bytes copied from actual bound views; this checks
/// domains only, without evaluating the translated physical algorithms.
fn ai(bytes : Bytes, index : Int32) -> Int32 raise {
  guard index >= 0 && index < bytes.length() / 4 else {
    fail("adapter metadata read exceeds snapshot")
  }
  let p = index * 4
  (bytes[p].to_uint() |
  (bytes[p + 1].to_uint() << 8) |
  (bytes[p + 2].to_uint() << 16) |
  (bytes[p + 3].to_uint() << 24)).reinterpret_as_int()
}

///|
pub fn validate_metadata(
  r : Request,
  key : String,
  data : Map[String, Bytes],
) -> Unit raise {
  validate(r)
  for name in immutable_parameters(r, key) {
    guard data.get(name) is Some(bytes) else {
      fail("missing actual adapter metadata: " + name)
    }
    let mut count = 1
    for n in expected_shape(r, name) {
      guard n == 0 || count <= 2147483647 / n else {
        fail("adapter metadata shape overflow")
      }
      count *= n
    }
    guard count <= 2147483647 / 4 && bytes.length() == count * 4 else {
      fail("adapter metadata byte count mismatch: " + name)
    }
    if dtype(name) == "float32" {
      for i in 0..<count {
        let v = Float::reinterpret_from_int(ai(bytes, i))
        guard !v.is_nan() &&
          !v.is_inf() &&
          (!(name == "D" || name == "frictionloss") || v >= 0.0F) else {
          fail("adapter authored numeric input is invalid")
        }
      }
    }
  }
  if data.contains("ncdof") {
    for w in 0..<r.nworld {
      let count = ai(data["ncdof"], w)
      guard count >= 0 && count <= r.nv && count <= r.nv_compact else {
        fail("compact active count exceeds either layout")
      }
      if data.contains("dof_cdof") && data.contains("cdof_dof") {
        let mut active = 0
        for full in 0..<r.nv {
          let c = ai(data["dof_cdof"], w * r.nv + full)
          guard c < count else {
            fail("full-to-compact index outside actual active prefix")
          }
          if c >= 0 {
            guard ai(data["cdof_dof"], w * r.nv_compact + c) == full else {
              fail("compact maps are not exact inverses")
            }
            active += 1
          }
        }
        guard active == count else { fail("compact map missing active DOF") }
        for c in 0..<r.nv_compact {
          let full = ai(data["cdof_dof"], w * r.nv_compact + c)
          if c < count {
            guard full >= 0 &&
              full < r.nv &&
              ai(data["dof_cdof"], w * r.nv + full) == c else {
              fail("compact inverse map invalid")
            }
          } else {
            guard full < 0 else {
              fail("padded compact slot must have negative full index")
            }
          }
        }
      }
    }
  }
  if data.contains("M_rownnz") {
    let mut prefix = 0
    for row in 0..<r.nv {
      let adr = ai(data["M_rowadr"], row)
      let nnz = ai(data["M_rownnz"], row)
      guard adr == prefix && nnz >= 1 && nnz <= r.mass_nnz - prefix else {
        fail("actual compact mass CSR row prefix invalid")
      }
      let mut previous = -1
      for k in adr..<(adr + nnz) {
        let col = ai(data["M_colind"], k)
        guard col > previous && col <= row else {
          fail("mass lower CSR columns not sorted unique bounded")
        }
        previous = col
      }
      guard previous == row else { fail("mass row diagonal must be last") }
      prefix += nnz
    }
    guard prefix == r.mass_nnz else {
      fail("mass CSR does not consume actual coefficients")
    }
  }
  if data.contains("M_mulm_rowadr") {
    guard ai(data["M_mulm_rowadr"], 0) == 0 &&
      ai(data["M_mulm_rowadr"], r.nv) == r.gather_nnz else {
      fail("actual symmetric mass gather CSR endpoints invalid")
    }
    for row in 0..<r.nv {
      let start = ai(data["M_mulm_rowadr"], row)
      let end = ai(data["M_mulm_rowadr"], row + 1)
      guard start >= 0 && end >= start && end <= r.gather_nnz else {
        fail("mass gather row interval invalid")
      }
      let seen : Map[Int32, Unit] = {}
      for k in start..<end {
        let col = ai(data["M_mulm_col"], k)
        let adr = ai(data["M_mulm_madr"], k)
        guard col >= 0 &&
          col < r.nv &&
          adr >= 0 &&
          adr < r.mass_nnz &&
          !seen.contains(col) else {
          fail("mass gather column/address invalid or duplicate")
        }
        seen[col] = ()
      }
    }
  }
  if data.contains("nefc") {
    for w in 0..<r.nworld {
      let count = ai(data["nefc"], w)
      guard count >= 0 && count <= r.njmax else {
        fail("adapter active constraint count invalid")
      }
      if data.contains("ne") {
        let ne = ai(data["ne"], w)
        let nf = ai(data["nf"], w)
        guard ne >= 0 && ne <= count && nf >= 0 && nf <= count - ne else {
          fail("adapter equality/friction partitions invalid")
        }
      }
      for row in 0..<count {
        if data.contains("efc_type") {
          let kind = ai(data["efc_type"], w * r.njmax + row)
          guard kind >= 0 && kind <= 6 else {
            fail("incremental adapter requires actual nonelliptic constraints")
          }
        }
        if data.contains("J_rownnz") {
          let adr = ai(data["J_rowadr"], w * r.njmax + row)
          let nnz = ai(data["J_rownnz"], w * r.njmax + row)
          guard adr >= 0 &&
            adr <= r.jacobian_capacity &&
            nnz >= 0 &&
            nnz <= r.jacobian_capacity - adr else {
            fail("actual Jacobian row interval invalid")
          }
          let seen : Map[Int32, Unit] = {}
          for k in adr..<(adr + nnz) {
            let col = ai(data["J_colind"], w * r.jacobian_capacity + k)
            guard col >= 0 && col < r.nv && !seen.contains(col) else {
              fail("actual Jacobian column invalid or duplicate")
            }
            seen[col] = ()
          }
        }
      }
    }
  }
}
