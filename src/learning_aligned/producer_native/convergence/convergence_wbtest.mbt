///|
/// Pending scientific regression sources; only typechecked during migration.
fn ray_world() -> RayWorld {
  {
    done: false,
    tolerance: 1.0e-8,
    ls_tolerance: 0.01,
    meaninertia: 1.0,
    ne: 0,
    nf: 0,
    rows: [],
    qacc: [0.0],
    ma: [0.0],
    qfrc_smooth: [1.0],
    search: [1.0],
    mv: [1.0],
    search_dot: 1.0,
    alpha: 7.0,
    improvement: 8.0,
    ls_exhausted: true,
    overflow: 4,
  }
}

///|
fn gate_world() -> ConvergenceWorld {
  {
    done: false,
    solver_niter: 0,
    overflow: 4,
    alpha: 1.0,
    improvement: 1.0,
    grad_dot: 1.0,
    newton_decrement: 2.0,
    tolerance: 0.01,
    meaninertia: 1.0,
    beta: 9.0,
    cg: Some({
      grad: [2.0],
      mgrad: [3.0],
      previous_grad: [1.0],
      previous_mgrad: [1.0],
    }),
  }
}

///|
fn rejected(work : () -> Unit raise) -> Bool {
  try {
    work()
    false
  } catch {
    _ => true
  }
}

///|
test "initial quadratic Newton step updates the real ray without bracketing" {
  let world = ray_world()
  let result = linesearch({
      nv: 1,
      njmax: 0,
      ls_iterations: 50,
      incremental: false,
      worlds: [world],
    })[0]
  assert_true(result.converged && !result.skipped_done)
  assert_eq(result.iterations_used, 0)
  assert_eq(result.state.alpha, 1.0)
  assert_eq(result.state.improvement, 0.5)
  assert_eq(result.state.qacc, [1.0])
  assert_eq(result.state.ma, [1.0])
  assert_true(result.state.ls_exhausted)
  assert_eq(result.state.overflow, 4)
  assert_eq(world.qacc, [0.0])
}

///|
test "unilateral active-set crossing requires dynamic bracketing and preserves capacity tail" {
  let row : RayRow = { jaref: -1.0, jv: 1.0, diagonal: 9.0, frictionloss: 0.0, }
  let world = {
    ..ray_world(),
    qfrc_smooth: [2.0],
    rows: [row, { ..row, jaref: 123.0, }],
  }
  let result = linesearch({
      nv: 1,
      njmax: 1,
      ls_iterations: 50,
      incremental: true,
      worlds: [world],
    })[0]
  assert_true(
    result.converged &&
    result.iterations_used > 0 &&
    result.iterations_used < 50,
  )
  assert_true((result.state.alpha - 2.0).abs() < 1.0e-12)
  assert_true((result.state.improvement - 6.5).abs() < 1.0e-12)
  assert_true((result.state.rows[0].jaref - 1.0).abs() < 1.0e-12)
  assert_eq(result.state.rows[1].jaref, 123.0)
  assert_false(result.state.ls_exhausted)
}

///|
test "line search zero iteration budget preserves overflow bits and marks exhausted ray" {
  let world = { ..ray_world(), qfrc_smooth: [0.0], mv: [0.0], }
  let result = linesearch({
      nv: 1,
      njmax: 0,
      ls_iterations: 0,
      incremental: true,
      worlds: [world],
    })[0]
  assert_false(result.converged)
  assert_eq(result.iterations_used, 0)
  assert_eq(result.state.alpha, 0.0)
  assert_eq(result.state.overflow, 1028)
  assert_true(result.state.ls_exhausted)
}

///|
test "done ray worlds preserve existing outputs" {
  let world = { ..ray_world(), done: true, }
  let result = linesearch({
      nv: 1,
      njmax: 0,
      ls_iterations: 50,
      incremental: true,
      worlds: [world],
    })[0]
  assert_true(result.skipped_done)
  assert_eq(result.state.alpha, 7.0)
  assert_eq(result.state.improvement, 8.0)
  assert_eq(result.state.overflow, 4)
  assert_eq(result.state.qacc, [0.0])
}

///|
test "friction saturation and unilateral cost shifting retain exact branches" {
  let row : RayRow = { jaref: 0.0, jv: 2.0, diagonal: 4.0, frictionloss: 2.0, }
  let positive = friction(row, 1.0)
  assert_eq(positive.x, 3.5)
  assert_eq(positive.y, 4.0)
  assert_eq(positive.z, 0.0)
  let negative = friction(row, -1.0)
  assert_eq(negative.x, 3.5)
  assert_eq(negative.y, -4.0)
  let boundary = friction(row, 0.25)
  assert_eq(boundary.x, 0.5)
  assert_eq(boundary.z, 0.0)
  let inactive = row_shifted({ ..row, jaref: -1.0, }, 1.0, false)
  assert_eq(inactive.x, -2.0)
  assert_eq(inactive.y, 0.0)
}

///|
test "Newton model decrement gate differs from CG and beta uses actual history" {
  let world = { ..gate_world(), newton_decrement: 0.0, }
  let request : ConvergenceRequest = {
    mode: "newton",
    nv: 1,
    iterations: 10,
    nsolving: 1,
    worlds: [world],
  }
  let newton = convergence(request)
  assert_true(newton.worlds[0].done)
  assert_eq(newton.nsolving, 0)
  assert_eq(newton.worlds[0].beta, 9.0)
  let cg = convergence({ ..request, mode: "cg", })
  assert_false(cg.worlds[0].done)
  assert_true(cg.continue_condition)
  assert_eq(cg.worlds[0].beta, 4.0)
  assert_eq(cg.worlds[0].solver_niter, 1)
}

///|
test "iteration exhaustion decrements nsolving exactly once and retains overflow flags" {
  let result = convergence({
    mode: "newton",
    nv: 1,
    iterations: 1,
    nsolving: 1,
    worlds: [gate_world()],
  })
  assert_true(result.worlds[0].done)
  assert_eq(result.worlds[0].overflow, 516)
  assert_eq(result.nsolving, 0)
  assert_false(result.continue_condition)
  let repeated = convergence({
    mode: "newton",
    nv: 1,
    iterations: 1,
    nsolving: 0,
    worlds: result.worlds,
  })
  assert_eq(repeated.nsolving, 0)
  assert_eq(repeated.worlds[0].solver_niter, 1)
  assert_eq(repeated.worlds[0].overflow, 516)
  let converged = convergence({
    mode: "newton",
    nv: 1,
    iterations: 1,
    nsolving: 1,
    worlds: [{ ..gate_world(), alpha: 0.0, }],
  })
  assert_eq(converged.worlds[0].overflow, 4)
}

///|
test "reject inconsistent loop state and malformed active CG vectors" {
  assert_true(
    rejected(fn() raise {
      ignore(
        prepare({
          operation: "linesearch",
          parameters: { "nv": 1, "cone": "elliptic", "worlds": [] },
        }),
      )
    }),
  )
  assert_true(
    rejected(fn() raise {
      ignore(
        convergence({
          mode: "newton",
          nv: 1,
          iterations: 10,
          nsolving: 0,
          worlds: [gate_world()],
        }),
      )
    }),
  )
  assert_true(
    rejected(fn() raise {
      ignore(
        convergence({
          mode: "cg",
          nv: 2,
          iterations: 10,
          nsolving: 1,
          worlds: [gate_world()],
        }),
      )
    }),
  )
  assert_true(
    rejected(fn() raise {
      ignore(
        convergence({
          mode: "newton",
          nv: 1,
          iterations: 1,
          nsolving: 1,
          worlds: [{ ..gate_world(), solver_niter: 1, }],
        }),
      )
    }),
  )
}
