///|
fn request(kernels : Array[String]) -> @physics_kernels.Request {
  {
    nworld: 2,
    nv: 35,
    ngeom: 40,
    npair: 100,
    njmax: 128,
    mass_nnz: 200,
    jacobian_capacity: 1024,
    filter_bits: 7,
    ngeom_aabb: 1,
    ngeom_rbound: 1,
    ngeom_margin: 1,
    ngeom_gap: 1,
    ngeom_dataid: 2,
    check_skip: true,
    compact: true,
    enable_sleep: false,
    incremental: false,
    kernels,
  }
}

///|
test "sparse mass and Jacobian force rebuild retain actual source contracts" {
  let module = @physics_kernels.lower(
    request([
      "mass-multiply-sparse", "constraint-force-zero-sparse", "constraint-force-rebuild-sparse",
    ]),
  )
  assert_eq(module.entries[0].source_function, "mul_m_kernel")
  assert_eq(module.entries[0].parameters.map(p => p.name), [
    "M_mulm_rowadr", "M_mulm_col", "M_mulm_madr", "M_in", "vec", "skip", "res",
  ])
  assert_eq(module.entries[2].launch_shape, [2, 128])
  assert_eq(module.entries[2].parameters[3].rank, 3)
  assert_true(module.source.contains("if(wp::index(skip,i)) continue;"))
  assert_true(
    module.source.contains(
      "col=wp::index(dof_cdof_in,i,col);if(col<0) continue;",
    ),
  )
  assert_true(
    module.source.contains(
      "wp::atomic_add(qfrc_constraint_out,i,col,value*force)",
    ),
  )
}

///|
test "NXN emits genuine candidate output contract without narrowphase claim" {
  let module = @physics_kernels.lower(request(["nxn-broadphase"]))
  let e = module.entries[0]
  assert_eq(e.source_function, "_nxn_broadphase")
  assert_eq(e.launch_shape, [2, 100])
  assert_eq(e.parameters.length(), 18)
  assert_true(e.helper_functions.contains("_aabb_filter"))
  assert_true(module.source.contains("if(keep||pairid[1]>=0)"))
  assert_true(
    module.source.contains("int cid=wp::atomic_add(ncollision_out,0,1)"),
  )
  assert_true(module.source.contains("if(cid>=naconmax_in)continue"))
  assert_true(module.source.contains("did=i%2"))
}

///|
test "unsupported broadphase variants and solver closure fail before compiler load" {
  let base = request(["nxn-broadphase"])
  for
    config in [
      { ..base, filter_bits: 8, },
      { ..base, enable_sleep: true, },
      { ..base, incremental: true, },
      { ..base, kernels: ["full-solver"], },
      { ..base, npair: 0, },
    ] {
    try @physics_kernels.lower(config) catch {
      _ => ()
    } noraise {
      _ => fail("unsupported specialization accepted")
    }
  }
}
