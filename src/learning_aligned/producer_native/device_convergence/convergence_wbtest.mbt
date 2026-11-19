///|
/// Pending source-only regressions, not run during migration.
fn rejects(work : () -> Unit raise) -> Bool {
  try {
    work()
    false
  } catch {
    _ => true
  }
}

///|
fn request() -> Request {
  {
    nworld: 2,
    nv: 3,
    iterations: 4,
    warn_overflow: 0,
    kernels: ["newton-done", "cg-beta-finalize"],
  }
}

///|
fn bindings(key : String) -> Array[Binding] raise {
  let lowered = lower(request())
  let selected = lowered.entries.filter(e => e.key == key)[0]
  selected.parameters.map(fn(p) {
    let shape = if p.name == "nsolving" {
      [1]
    } else if p.rank == 2 {
      [2, 3]
    } else {
      [2]
    }
    let width = if p.dtype == "bool" { 1 } else { 4 }
    {
      name: p.name,
      allocation: p.name,
      dtype: p.dtype,
      shape,
      byte_strides: if p.rank == 2 {
        [3 * width, width]
      } else {
        [width]
      },
      byte_offset: 0L,
      buffer_bytes: (shape.fold(init=1, fn(a, b) { a * b }) * width).to_int64(),
    }
  })
}

///|
test "device convergence rejects unsupported warning and unbounded dimensions" {
  for
    bad in [
      { ..request(), warn_overflow: 512, },
      { ..request(), iterations: 0, },
      { ..request(), nv: 0, },
      { ..request(), kernels: ["placeholder-loop"], },
    ] {
    assert_true(rejects(fn() { ignore(lower(bad)) }))
  }
}

///|
test "device convergence bindings enforce exact world vectors and distinct writable owners" {
  let views = bindings("cg-beta-finalize")
  validate_bindings(request(), "cg-beta-finalize", views)
  let wrong = views.map(v => {
    if v.name == "ctx_grad" {
      { ..v, shape: [2, 2], }
    } else {
      v
    }
  })
  assert_true(
    rejects(fn() { validate_bindings(request(), "cg-beta-finalize", wrong) }),
  )
  let alias = views.map(v => {
    if v.name == "ctx_beta" {
      { ..v, allocation: "ctx_grad_dot", }
    } else {
      v
    }
  })
  assert_true(
    rejects(fn() { validate_bindings(request(), "cg-beta-finalize", alias) }),
  )
}

///|
test "device convergence full span is checked before launch" {
  let views = bindings("newton-done")
  let short = views.map(v => {
    if v.name == "solver_niter" {
      { ..v, byte_offset: 4L, }
    } else {
      v
    }
  })
  assert_true(
    rejects(fn() { validate_bindings(request(), "newton-done", short) }),
  )
}

///|
test "device convergence model option batches reject guessed extent" {
  let views = bindings("newton-done")
  let bad = views.map(v => {
    if v.name == "stat_meaninertia" {
      { ..v, shape: [3], buffer_bytes: 12L, }
    } else {
      v
    }
  })
  assert_true(
    rejects(fn() { validate_bindings(request(), "newton-done", bad) }),
  )
}

///|
/// Pending source-only fused-tail regression, never run during migration.
test "actual fused convergence keys have search and line overflow operands" {
  let r = {
    ..request(),
    kernels: ["newton-done-with-ls", "cg-beta-search-finalize"],
  }
  let l = lower(r)
  assert_true(l.entries.all(e => !e.forward.contains("-")))
  assert_true(l.entries[0].parameters.any(p => p.name == "ls_overflow"))
  assert_true(
    l.entries[1].parameters.any(p => {
      p.name == "ctx_search" && p.access == "inout"
    }),
  )
}
