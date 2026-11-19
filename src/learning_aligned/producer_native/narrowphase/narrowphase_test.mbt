///|
fn request(pairs : Array[String]) -> @narrowphase.Request {
  {
    nworld: 2,
    ngeom: 40,
    candidate_capacity: 100,
    contact_capacity: 800,
    efc_slots: 10,
    pairs,
  }
}

///|
test "native primitive module preserves typed contact and rejection contracts" {
  let module = @narrowphase.lower(request(@narrowphase.supported_pairs()))
  assert_eq(module.entry.launch_shape, [100])
  assert_eq(module.entry.forward, "mr_mjw_native_primitive_contacts")
  let params = module.entry.parameters
  assert_eq(params.length(), 42)
  assert_eq(params[5].name, "geom_solimp")
  assert_eq(params[5].dtype, "vec5f")
  assert_eq(params[35].name, "contact_efc_address_out")
  assert_eq(params[35].rank, 2)
  assert_eq(params[41].name, "rejected_out")
  assert_eq(params[41].access, "inout")
}

///|
test "unsupported collision pairs fail before compiler loading" {
  for pair in ["box-box", "plane-mesh", "hfield", "gjk", "epa", "sdf"] {
    try @narrowphase.lower(request([pair])) catch {
      _ => ()
    } noraise {
      _ => fail("unsupported pair accepted")
    }
  }
}

///|
test "narrowphase specialization rejects ambiguous and overflowing capacities" {
  let base = request(["plane-sphere"])
  for
    config in [
      { ..base, pairs: [], },
      { ..base, pairs: ["plane-sphere", "plane-sphere"], },
      { ..base, candidate_capacity: 0, },
      { ..base, candidate_capacity: 268435456, },
      { ..base, contact_capacity: -1, },
      { ..base, efc_slots: 0, },
    ] {
    try @narrowphase.lower(config) catch {
      _ => ()
    } noraise {
      _ => fail("invalid narrowphase plan accepted")
    }
  }
}
