///|
/// Pending source/metadata regressions only. Not executed during migration.
fn example_request() -> Request {
  {
    nworld: 2,
    nv: 3,
    njmax: 4,
    ncon: 0,
    mass_nnz: 6,
    jacobian_capacity: 12,
    iterations: 2,
    ls_iterations: 4,
    solver: "newton",
    jacobian_layout: "dense",
    mass_layout: "csr",
    cone: "pyramidal",
    warmstart: true,
    kernels: [
      "initialize-controls", "initialize-state", "constraint-gradient-hessian", "factor-direction",
      "line-search", "line-search-incremental",
    ],
  }
}

///|
test "Newton real entries use valid identifiers and constant line bound" {
  let l = lower(example_request())
  assert_true(l.entries.all(e => !e.forward.contains("-")))
  assert_true(l.source.contains("constexpr int MR_LS_ITERATIONS=4;"))
  assert_true(!l.source.contains("{r."))
  assert_true(l.source.contains("ctx_ls_exhausted"))
}

///|
test "Newton canonical initializer has the small real control signature" {
  let l = lower(example_request())
  let e = l.entries.filter(e => e.key == "initialize-controls")[0]
  assert_eq(e.parameters.map(p => p.name), [
    "ctx_done", "solver_niter", "nsolving", "ctx_search_dot", "status",
  ])
}

///|
test "Newton zero iteration and zero contact capacities are genuine source branches" {
  ignore(lower({ ..example_request(), iterations: 0, }))
  let r = {
    ..example_request(),
    nv: 0,
    mass_nnz: 0,
    jacobian_capacity: 0,
    kernels: ["unconstrained"],
  }
  assert_eq(lower(r).entries[0].key, "unconstrained")
}
