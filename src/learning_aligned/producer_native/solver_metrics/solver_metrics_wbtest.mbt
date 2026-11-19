///|
// Pending host-only regression definitions. Not executed during migration.
fn pending_request() -> Request {
  {
    nworld: 2,
    nv: 3,
    nC: 6,
    nK: 0,
    nblock: 1,
    nefm0: 0,
    nefm0L: 0,
    ntendon: 0,
    tendon_nnz: 0,
    nactuator: 0,
    moment_nnz: 0,
    njmax: 0,
    jacobian_nnz: 0,
    ncon: 0,
    contact_width: 0,
    ntree: 0,
    sparse_jacobian: false,
    sleep: false,
    check_skip: true,
    architecture: 80,
    kernels: [
      "effective-force", "copy-backbone-rhs", "block-solve", "build-blocks", "factor-blocks",
      "factor-folded-blocks", "mul-diag", "mul-diag-csr", "mul-fluid", "add-qh-diag",
      "add-fluid-qh",
    ],
  }
}

///|
test "pending real helper source and no-constraint dense block branch" {
  let result = lower(pending_request())
  assert_eq(result.entries.length(), 11)
  assert_eq(result.launch_policy.grid_stride, false)
  assert_true(result.source.contains("wp::atomic_or(failure,w,1)"))
  assert_true(result.source.contains("1.0e-15f"))
  assert_true(!result.entries[3].parameters.any(p => p.name == "efc_J"))
  assert_true(result.entries.all(e => !e.forward.contains("-")))
  assert_eq(result.entries[1].forward, "mr_mjw_metric_copy_backbone_rhs")
}

///|
test "pending exact block-only program uses actual factors" {
  let r = pending_request()
  let views : Map[String, Json] = Map([])
  for p in params(r, "block-solve") {
    views[p.name] = { "buffer": Json(p.name) }
  }
  let commands = preconditioner_plan({
    request: r,
    module_name: "effective",
    mixed_module: "",
    mixed_request: None,
    views,
    mixed_views: Map([]),
    efm0_active: false,
    folded_blocks: false,
    fold_contact: false,
  })
  assert_eq(commands.length(), 1)
  assert_true(
    commands[0] is { "parameters": { "entry": String("block-solve"), .. }, .. },
  )
}

///|
test "pending malformed failure rejected" {
  try validate_initial_failure(2, b"\x00\x00\x00\x00") catch {
    _ => ()
  } noraise {
    _ => fail("truncated failure accepted")
  }
}

///|
test "pending matvec input output owner alias rejected" {
  let r = pending_request()
  let bs = params(r, "mul-diag").map(p => {
    let shape = expected_shape(r, p.name)
    let width = if p.dtype == "bool" { 1 } else { 4 }
    let strides = if shape.length() == 2 {
      [width * shape[1], width]
    } else {
      [width]
    }
    {
      name: p.name,
      owner: if p.name == "vec" || p.name == "res" {
        "same"
      } else {
        p.name
      },
      dtype: p.dtype,
      shape,
      byte_strides: strides,
      offset_bytes: 0UL,
      capacity_bytes: 64UL,
    }
  })
  try validate_bindings(r, "mul-diag", bs) catch {
    _ => ()
  } noraise {
    _ => fail("aliased matvec accepted")
  }
}
