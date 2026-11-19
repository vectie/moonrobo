// Copyright 2026 The Newton Developers
// SPDX-License-Identifier: Apache-2.0
// Scalar formula/order port from MuJoCo-Warp 3.15.0 solver.py (Newton Developers).

///|
fn in_bracket(x : @geometry.Vec3, y : @geometry.Vec3) -> Bool {
  (x.y < y.y && y.y < 0.0) || (x.y > y.y && y.y > 0.0)
}

///|
fn quadratic(
  q : @geometry.Vec3,
  alpha : Double,
) -> @geometry.Vec3 raise ConvergenceError {
  let aq2 = alpha * q.z
  point(alpha * aq2 + alpha * q.y + q.x, 2.0 * aq2 + q.y, 2.0 * q.z)
}

///|
fn direct(
  row : RayRow,
  alpha : Double,
  offset : Double,
) -> @geometry.Vec3 raise ConvergenceError {
  let grad0 = row.jv * row.diagonal * row.jaref
  let hessian = row.jv * (row.jv * row.diagonal)
  let ah = alpha * hessian
  point(alpha * (grad0 + 0.5 * ah) + offset, grad0 + ah, hessian)
}

///|
fn friction(
  row : RayRow,
  alpha : Double,
) -> @geometry.Vec3 raise ConvergenceError {
  let x = row.jaref + alpha * row.jv
  let rf = safe_div(row.frictionloss, row.diagonal)
  if -rf < x && x < rf {
    let jvd = row.jv * row.diagonal
    point(0.5 * row.diagonal * x * x, jvd * x, row.jv * jvd)
  } else if x <= -rf {
    point(row.frictionloss * (-0.5 * rf - x), -row.frictionloss * row.jv, 0.0)
  } else {
    point(row.frictionloss * (-0.5 * rf + x), row.frictionloss * row.jv, 0.0)
  }
}

///|
fn row_zero(
  row : RayRow,
  is_friction : Bool,
) -> @geometry.Vec3 raise ConvergenceError {
  if is_friction {
    return friction(row, 0.0)
  }
  if row.jaref < 0.0 {
    let jvd = row.jv * row.diagonal
    point(
      0.5 * row.diagonal * row.jaref * row.jaref,
      jvd * row.jaref,
      row.jv * jvd,
    )
  } else {
    point(0.0, 0.0, 0.0)
  }
}

///|
fn row_shifted(
  row : RayRow,
  alpha : Double,
  is_friction : Bool,
) -> @geometry.Vec3 raise ConvergenceError {
  if is_friction {
    let pt = friction(row, alpha)
    return point(pt.x - friction(row, 0.0).x, pt.y, pt.z)
  }
  let q0 = 0.5 * row.diagonal * row.jaref * row.jaref
  let cost0 = if row.jaref < 0.0 { q0 } else { 0.0 }
  if row.jaref + alpha * row.jv < 0.0 {
    direct(row, alpha, q0 - cost0)
  } else {
    point(-cost0, 0.0, 0.0)
  }
}

///|
fn evaluate(
  world : RayWorld,
  effective : Int32,
  gauss : @geometry.Vec3,
  alpha : Double,
) -> @geometry.Vec3 raise ConvergenceError {
  let mut value = quadratic(gauss, alpha)
  for i in world.ne..<effective {
    value = add(
      value,
      row_shifted(world.rows[i], alpha, i < world.ne + world.nf),
    )
  }
  value
}

///|
fn validate_world(
  world : RayWorld,
  nv : Int32,
  effective : Int32,
) -> Unit raise ConvergenceError {
  guard nv > 0 &&
    world.rows.length() <= 1000000 &&
    world.ne >= 0 &&
    world.nf >= 0 &&
    world.ne <= effective &&
    world.nf <= effective - world.ne &&
    world.tolerance >= 0.0 &&
    world.ls_tolerance >= 0.0 &&
    world.meaninertia > 0.0 &&
    world.search_dot >= 0.0 &&
    valid([
      world.tolerance,
      world.ls_tolerance,
      world.meaninertia,
      world.search_dot,
      world.alpha,
      world.improvement,
    ]) &&
    world.overflow >= 0 else {
    raise Invalid(
      "invalid ray world counts, tolerances, norm, inertia or existing outputs",
    )
  }
  for
    vector in [world.qacc, world.ma, world.qfrc_smooth, world.search, world.mv] {
    guard vector.length() == nv && valid(vector) else {
      raise Invalid("ray vector width/finite values differ from nv")
    }
  }
  for row in world.rows {
    guard valid([row.jaref, row.jv, row.diagonal, row.frictionloss]) &&
      row.diagonal >= 0.0 &&
      row.frictionloss >= 0.0 else {
      raise Invalid("ray constraint diagonal/frictionloss/values are invalid")
    }
  }
}

///|
fn search_world(
  request : LineSearchRequest,
  world : RayWorld,
) -> LineSearchWorld raise ConvergenceError {
  let effective = @math.minimum(request.njmax, world.rows.length())
  validate_world(world, request.nv, effective)
  if world.done {
    return {
      state: {
        ..world,
        qacc: world.qacc.copy(),
        ma: world.ma.copy(),
        rows: world.rows.copy(),
      },
      iterations_used: 0,
      converged: false,
      skipped_done: true,
    }
  }
  let mut q1 = 0.0
  let mut q2 = 0.0
  for i in 0..<request.nv {
    q1 += world.search[i] * (world.ma[i] - world.qfrc_smooth[i])
    q2 += 0.5 * world.search[i] * world.mv[i]
  }
  for i in 0..<world.ne {
    let row = world.rows[i]
    let jvd = row.jv * row.diagonal
    q1 += jvd * row.jaref
    q2 += 0.5 * row.jv * jvd
  }
  let gauss = point(0.0, q1, q2)
  let mut rows0 = point(0.0, 0.0, 0.0)
  for i in world.ne..<effective {
    rows0 = add(rows0, row_zero(world.rows[i], i < world.ne + world.nf))
  }
  let p0 = add(point(gauss.x, gauss.y, 2.0 * gauss.z), rows0)
  let q1_abs = checked(
    (2.0 * @math.maximum(rows0.x, 0.0) * @math.maximum(rows0.z, 0.0)).sqrt() +
    gauss.y.abs(),
  )
  let noise_eps = 8.0 * 1.1920929e-07
  let gtol = checked(
    @math.maximum(
      world.tolerance *
      world.ls_tolerance *
      world.search_dot.sqrt() *
      (world.meaninertia * request.nv.to_double()),
      1.0e-6,
    ),
  )
  let acceptance = @math.maximum(gtol, noise_eps * q1_abs)
  let noise_floor = if request.incremental {
    checked(noise_eps * @math.maximum(1.0, safe_div(q1_abs, p0.z)))
  } else {
    0.0
  }
  let initial_alpha = checked(-safe_div(p0.y, p0.z))
  let initial = evaluate(world, effective, gauss, initial_alpha)
  let initial_done = initial.y.abs() < acceptance && initial.x < 0.0
  let mut converged = initial_done
  let mut alpha = if initial_done { initial_alpha } else { 0.0 }
  let mut improvement = if initial_done { -initial.x } else { 0.0 }
  let mut iterations_used = 0
  if !initial_done {
    let less = initial.y < p0.y
    let anchor = point(0.0, p0.y, p0.z)
    let mut lo = if less { initial } else { anchor }
    let mut hi = if less { anchor } else { initial }
    let mut lo_alpha = if less { initial_alpha } else { 0.0 }
    let mut hi_alpha = if less { 0.0 } else { initial_alpha }
    for iteration in 0..<request.ls_iterations {
      iterations_used = iteration + 1
      let ln_alpha = checked(lo_alpha - safe_div(lo.y, lo.z))
      let hn_alpha = checked(hi_alpha - safe_div(hi.y, hi.z))
      let mid_alpha = checked(0.5 * (lo_alpha + hi_alpha))
      let ln = evaluate(world, effective, gauss, ln_alpha)
      let hn = evaluate(world, effective, gauss, hn_alpha)
      let mid = evaluate(world, effective, gauss, mid_alpha)
      let cl = ln.y.abs() < acceptance && ln.x < 0.0
      let ch = hn.y.abs() < acceptance && hn.x < 0.0
      let cm = mid.y.abs() < acceptance && mid.x < 0.0
      let found = cl || ch || cm
      let mut swap_lo = false
      let mut swap_hi = false
      if found {
        let mut candidate : (@geometry.Vec3, Double)? = None
        for
          (ok, pt, a) in [
            (cl, ln, ln_alpha),
            (ch, hn, hn_alpha),
            (cm, mid, mid_alpha),
          ] {
          if ok &&
            (match candidate {
              None => true
              Some((best, _)) => pt.x < best.x
            }) {
            candidate = Some((pt, a))
          }
        }
        let (best, a) = candidate.unwrap()
        lo = best
        hi = best
        lo_alpha = a
        hi_alpha = a
      } else {
        for (pt, a) in [(ln, ln_alpha), (mid, mid_alpha), (hn, hn_alpha)] {
          if in_bracket(lo, pt) {
            lo = pt
            lo_alpha = a
            swap_lo = true
          }
        }
        if in_bracket(hi, hn) || (hi.y < 0.0 && hn.y > 0.0) {
          hi = hn
          hi_alpha = hn_alpha
          swap_hi = true
        }
        for (pt, a) in [(mid, mid_alpha), (ln, ln_alpha)] {
          if in_bracket(hi, pt) {
            hi = pt
            hi_alpha = a
            swap_hi = true
          }
        }
      }
      let done = found ||
        (!swap_lo && !swap_hi) ||
        (lo.x < 0.0 && lo.y < 0.0 && lo.y > -gtol) ||
        (hi.x < 0.0 && hi.y > 0.0 && hi.y < gtol)
      if lo.x < 0.0 || hi.x < 0.0 {
        let best = if lo.x < hi.x { (lo, lo_alpha) } else { (hi, hi_alpha) }
        alpha = best.1
        improvement = -best.0.x
      }
      if done {
        converged = true
        break
      }
    }
  }
  let qacc = Array::makei(request.nv, i => {
    checked(world.qacc[i] + alpha * world.search[i])
  })
  let ma = Array::makei(request.nv, i => {
    checked(world.ma[i] + alpha * world.mv[i])
  })
  let rows = world.rows.mapi(fn(i, row) {
    if i < effective {
      { ..row, jaref: checked(row.jaref + alpha * row.jv), }
    } else {
      row
    }
  })
  {
    state: {
      ..world,
      qacc,
      ma,
      rows,
      alpha,
      improvement,
      ls_exhausted: if request.incremental {
        alpha.abs() < noise_floor
      } else {
        world.ls_exhausted
      },
      overflow: if converged {
        world.overflow
      } else {
        world.overflow | 1024
      },
    },
    iterations_used,
    converged,
    skipped_done: false,
  }
}

///|
/// Real dynamic scalar bracketing loop; ls_iterations is only its upper bound.
pub fn linesearch(
  request : LineSearchRequest,
) -> Array[LineSearchWorld] raise ConvergenceError {
  guard request.nv > 0 &&
    request.nv <= 1000000 &&
    request.njmax >= 0 &&
    request.njmax <= 1000000 &&
    request.ls_iterations >= 0 &&
    request.ls_iterations <= 1000000 &&
    request.worlds.length() <= 1000000 else {
    raise Invalid("unsupported line-search shape or iteration bound")
  }
  request.worlds.map(world => search_world(request, world))
}
