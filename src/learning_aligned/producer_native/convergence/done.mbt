// Copyright 2026 The Newton Developers
// SPDX-License-Identifier: Apache-2.0
// MuJoCo-Warp 3.15.0 solver.py: _solve_beta_finalize_tiled and _solve_done.

///|
fn copy_cg(value : CgVectors?) -> CgVectors? {
  value.map(v => {
    grad: v.grad.copy(),
    mgrad: v.mgrad.copy(),
    previous_grad: v.previous_grad.copy(),
    previous_mgrad: v.previous_mgrad.copy(),
  })
}

///|
fn beta(vectors : CgVectors, nv : Int32) -> Double raise ConvergenceError {
  for
    vector in [
      vectors.grad,
      vectors.mgrad,
      vectors.previous_grad,
      vectors.previous_mgrad,
    ] {
    guard vector.length() == nv && valid(vector) else {
      raise Invalid("CG vectors must contain nv finite values")
    }
  }
  let mut numerator = 0.0
  let mut denominator = 0.0
  for i in 0..<nv {
    numerator = checked(
      numerator +
      vectors.grad[i] * (vectors.mgrad[i] - vectors.previous_mgrad[i]),
    )
    denominator = checked(
      denominator + vectors.previous_grad[i] * vectors.previous_mgrad[i],
    )
  }
  checked(@math.maximum(0.0, numerator / @math.maximum(1.0e-15, denominator)))
}

///|
/// One actual solver done/beta transition for all worlds. Callers supply the
/// current iteration's real gradient/ray results; this never fabricates solver
/// iterations or executes a fixed-repeat approximation of the device loop.
pub fn convergence(
  request : ConvergenceRequest,
) -> ConvergenceResult raise ConvergenceError {
  guard request.mode == "newton" || request.mode == "cg" else {
    raise Unsupported("convergence mode must be newton or cg")
  }
  guard request.nv > 0 &&
    request.nv <= 1000000 &&
    request.iterations > 0 &&
    request.iterations <= 1000000 &&
    request.worlds.length() <= 1000000 &&
    request.nsolving >= 0 else {
    raise Invalid("invalid convergence shape/iteration limit")
  }
  let unfinished = request.worlds.filter(world => !world.done).length()
  guard request.nsolving == unfinished else {
    raise Invalid("nsolving must equal the actual unfinished world count")
  }
  let mut nsolving = request.nsolving
  let worlds = request.worlds.map(fn(world) {
    guard world.solver_niter >= 0 &&
      world.solver_niter <= request.iterations &&
      world.overflow >= 0 &&
      world.meaninertia > 0.0 &&
      world.tolerance >= 0.0 &&
      world.grad_dot >= 0.0 &&
      valid([
        world.alpha,
        world.improvement,
        world.grad_dot,
        world.newton_decrement,
        world.tolerance,
        world.meaninertia,
        world.beta,
      ]) else {
      raise Invalid("invalid convergence world state or nonfinite input")
    }
    // The upstream kernels return before touching outputs for an already done world.
    if world.done {
      return { ..world, cg: copy_cg(world.cg), }
    }
    guard world.solver_niter < request.iterations else {
      raise Invalid("unfinished world already reached the iteration limit")
    }
    let updated_beta = if request.mode == "cg" {
      guard world.cg is Some(vectors) else {
        raise Invalid("CG convergence requires actual gradient history vectors")
      }
      beta(vectors, request.nv)
    } else {
      world.beta
    }
    let scale = checked(world.meaninertia * request.nv.to_double())
    let improvement = checked(world.improvement / scale)
    let gradient = checked(world.grad_dot.sqrt() / scale)
    let mut done = world.alpha == 0.0 ||
      (improvement > 0.0 && improvement < world.tolerance) ||
      gradient < world.tolerance
    if request.mode == "newton" {
      let model_improvement = checked(0.5 * world.newton_decrement / scale)
      done = done || model_improvement < world.tolerance
    }
    let solver_niter = world.solver_niter + 1
    let at_limit = solver_niter == request.iterations
    let overflow = if !done && at_limit {
      world.overflow | 512
    } else {
      world.overflow
    }
    if done || at_limit {
      nsolving -= 1
    }
    {
      ..world,
      done: done || at_limit,
      solver_niter,
      overflow,
      beta: updated_beta,
      cg: copy_cg(world.cg),
    }
  })
  { worlds, nsolving, continue_condition: nsolving > 0, }
}
