// Batched differentiable geometry. All matrices are [B,3,3], vectors [B,D].
// Internal and replay quaternions are WXYZ, as in aligned/rotations.py.

///|
fn col(x : @tensor.Tensor, i : Int32) -> @tensor.Tensor raise {
  x.narrow(1, i, 1)
}

///|
fn entry(x : @tensor.Tensor, i : Int32) -> @tensor.Tensor raise {
  col(x.reshape([-1, 9]), i)
}

///|
fn columns(
  backend : @tensor.Backend,
  xs : Array[@tensor.Tensor],
) -> @tensor.Tensor raise {
  backend.concat(xs, axis=1)
}

///|
fn mat(
  backend : @tensor.Backend,
  xs : Array[@tensor.Tensor],
) -> @tensor.Tensor raise {
  columns(backend, xs).reshape([-1, 3, 3])
}

///|
fn mv(r : @tensor.Tensor, v : @tensor.Tensor) -> @tensor.Tensor raise {
  r.matmul(v.reshape([-1, 3, 1])).reshape([-1, 3])
}

///|
fn tr(r : @tensor.Tensor) -> @tensor.Tensor raise {
  r.transpose_dims(1, 2)
}

///|
fn normed(x : @tensor.Tensor) -> @tensor.Tensor raise {
  x.div(x.square().sum_dim(1, keepdim=true).clamp(1.0e-24, 1.0e30).sqrt())
}

///|
fn cross(
  backend : @tensor.Backend,
  a : @tensor.Tensor,
  b : @tensor.Tensor,
) -> @tensor.Tensor raise {
  columns(backend, [
    col(a, 1).mul(col(b, 2)).sub(col(a, 2).mul(col(b, 1))),
    col(a, 2).mul(col(b, 0)).sub(col(a, 0).mul(col(b, 2))),
    col(a, 0).mul(col(b, 1)).sub(col(a, 1).mul(col(b, 0))),
  ])
}

///|
pub fn quat_to_mat(
  backend : @tensor.Backend,
  input : @tensor.Tensor,
) -> @tensor.Tensor raise {
  let q = normed(input)
  let w = col(q, 0)
  let x = col(q, 1)
  let y = col(q, 2)
  let z = col(q, 3)
  mat(backend, [
    y.square().add(z.square()).affine(-2.0, bias=1.0),
    x.mul(y).sub(w.mul(z)).affine(2.0),
    x.mul(z).add(w.mul(y)).affine(2.0),
    x.mul(y).add(w.mul(z)).affine(2.0),
    x.square().add(z.square()).affine(-2.0, bias=1.0),
    y.mul(z).sub(w.mul(x)).affine(2.0),
    x.mul(z).sub(w.mul(y)).affine(2.0),
    y.mul(z).add(w.mul(x)).affine(2.0),
    x.square().add(y.square()).affine(-2.0, bias=1.0),
  ])
}

///|
pub fn mat_to_quat(
  backend : @tensor.Backend,
  m : @tensor.Tensor,
) -> @tensor.Tensor raise {
  let m0 = entry(m, 0)
  let m1 = entry(m, 1)
  let m2 = entry(m, 2)
  let m3 = entry(m, 3)
  let m4 = entry(m, 4)
  let m5 = entry(m, 5)
  let m6 = entry(m, 6)
  let m7 = entry(m, 7)
  let m8 = entry(m, 8)
  let cands = [
    m0
    .add(m4)
    .add(m8)
    .affine(1.0, bias=1.0)
    .clamp(1.0e-10, 1.0e30)
    .sqrt()
    .affine(0.5),
    m0
    .sub(m4)
    .sub(m8)
    .affine(1.0, bias=1.0)
    .clamp(1.0e-10, 1.0e30)
    .sqrt()
    .affine(0.5),
    m4
    .sub(m0)
    .sub(m8)
    .affine(1.0, bias=1.0)
    .clamp(1.0e-10, 1.0e30)
    .sqrt()
    .affine(0.5),
    m8
    .sub(m0)
    .sub(m4)
    .affine(1.0, bias=1.0)
    .clamp(1.0e-10, 1.0e30)
    .sqrt()
    .affine(0.5),
  ]
  let d0 = cands[0].affine(4.0)
  let d1 = cands[1].affine(4.0)
  let d2 = cands[2].affine(4.0)
  let d3 = cands[3].affine(4.0)
  let choices = [
    columns(backend, [
      cands[0],
      m7.sub(m5).div(d0),
      m2.sub(m6).div(d0),
      m3.sub(m1).div(d0),
    ]),
    columns(backend, [
      m7.sub(m5).div(d1),
      cands[1],
      m1.add(m3).div(d1),
      m2.add(m6).div(d1),
    ]),
    columns(backend, [
      m2.sub(m6).div(d2),
      m1.add(m3).div(d2),
      cands[2],
      m5.add(m7).div(d2),
    ]),
    columns(backend, [
      m3.sub(m1).div(d3),
      m2.add(m6).div(d3),
      m5.add(m7).div(d3),
      cands[3],
    ]),
  ]
  let mut best = cands[0]
  let mut q = choices[0]
  for i in 1..<4 {
    let choose = cands[i].greater(best)
    q = choose.select_where(choices[i], q)
    best = choose.select_where(cands[i], best)
  }
  let q = normed(q)
  let w = col(q, 0)
  w.less(w.affine(0.0)).select_where(q.affine(-1.0), q)
}

///|
/// The SMC projection has a different derivative near a vertical forward axis.
/// Keep the legacy fallback available for existing training checkpoints.
pub(all) enum HeadingMode {
  GenCoordYaw
  StableFallback
  SmcProjected
  // Piecewise SO(3) chart: longer horizontal body axis, forward on ties.
  // Explicitly nonsmooth at chart seams; unlike SmcProjected never contracts XY.
  OrthonormalAtlas
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn yaw_mat(
  backend : @tensor.Backend,
  r : @tensor.Tensor,
  mode~ : HeadingMode = StableFallback,
  compact~ : Bool = false,
  source_order~ : Bool = false,
) -> @tensor.Tensor raise {
  if source_order && mode == SmcProjected {
    return r.heading_matrix_smc()
  }
  if source_order && mode == StableFallback {
    return r.heading_matrix_stable()
  }
  if compact && mode == SmcProjected {
    return r.compact_heading()
  }
  let x = entry(r, 0)
  let y = entry(r, 3)
  if mode == GenCoordYaw {
    let yaw = y.atan2(x)
    let s = yaw.sin()
    let c = yaw.cos()
    let z = x.stop_gradient().affine(0.0)
    return mat(backend, [
      c,
      s.affine(-1.0),
      z,
      s,
      c,
      z,
      z,
      z,
      z.affine(0.0, bias=1.0),
    ])
  }
  if mode == OrthonormalAtlas {
    let lx = entry(r, 4)
    let ly = entry(r, 1).affine(-1.0)
    let use_left = lx.mul(lx).add(ly.mul(ly)).greater(x.mul(x).add(y.mul(y)))
    let a = use_left.select_where(lx, x)
    let b = use_left.select_where(ly, y)
    // On SO(3), selected squared norm >= 1/2. The floor only protects invalid
    // inputs; unlike epsilon addition it has no effect on valid rotations.
    // Keep the two multiplication edges at the same gradient join as the
    // mathematical control and the compiled rollout's corrected heading.
    let n = a.mul(a).add(b.mul(b)).clamp(1.0e-24, 1.0e30).sqrt()
    let c = a.div(n)
    let s = b.div(n)
    let zero = c.stop_gradient().affine(0.0)
    return mat(backend, [
      c,
      s.affine(-1.0),
      zero,
      s,
      c,
      zero,
      zero,
      zero,
      zero.affine(0.0, bias=1.0),
    ])
  }
  if mode == SmcProjected {
    // Exact regularization from supermimic/rotations.py::yaw_mat.
    let n = x.square().add(y.square()).affine(1.0, bias=1.0e-9).sqrt()
    let c = x.div(n)
    let s = y.div(n)
    let zero = c.stop_gradient().affine(0.0)
    return mat(backend, [
      c,
      s.affine(-1.0),
      zero,
      s,
      c,
      zero,
      zero,
      zero,
      zero.affine(0.0, bias=1.0),
    ])
  }
  let vertical = x.square().add(y.square()).less(x.affine(0.0, bias=1.0e-12))
  let x = vertical.select_where(entry(r, 4), x)
  let y = vertical.select_where(entry(r, 1).affine(-1.0), y)
  let n = x.square().add(y.square()).clamp(1.0e-24, 1.0e30).sqrt()
  let c = x.div(n)
  let s = y.div(n)
  let zero = c.affine(0.0)
  mat(backend, [
    c,
    s.affine(-1.0),
    zero,
    s,
    c,
    zero,
    zero,
    zero,
    zero.affine(0.0, bias=1.0),
  ])
}

///|
pub fn mat_to_6d(r : @tensor.Tensor) -> @tensor.Tensor raise {
  r.narrow(2, 0, 2).reshape([-1, 6])
}

///|
fn skew(
  backend : @tensor.Backend,
  v : @tensor.Tensor,
  detached_constants~ : Bool = false,
) -> @tensor.Tensor raise {
  let x = col(v, 0)
  let y = col(v, 1)
  let z = col(v, 2)
  let zero = (if detached_constants { x.stop_gradient() } else { x }).affine(
    0.0,
  )
  mat(backend, [
    zero,
    z.affine(-1.0),
    y,
    z,
    zero,
    x.affine(-1.0),
    y.affine(-1.0),
    x,
    zero,
  ])
}

///|
pub fn so3_exp(
  backend : @tensor.Backend,
  v : @tensor.Tensor,
  detached_constants~ : Bool = false,
  compact_skew~ : Bool = false,
  fused_skew~ : Bool = false,
  fused_so3_tail~ : Bool = false,
  fused_so3_coefficients~ : Bool = false,
  fused_so3_coefficients_forward~ : Bool = false,
  fused_so3_coefficients_full~ : Bool = false,
  split_so3_coefficients~ : Bool = false,
) -> @tensor.Tensor raise {
  guard (
      !fused_so3_coefficients_full &&
      !fused_so3_coefficients_forward &&
      !split_so3_coefficients
    ) ||
    fused_so3_coefficients else {
    fail("coefficient optimizations require accepted coefficient VJP")
  }
  let theta2 = v.square().sum_dim(1, keepdim=true)
  let (a, b) = if fused_so3_coefficients {
    let coefficients = if fused_so3_coefficients_full {
      theta2.so3_coefficient_full_forward()
    } else if fused_so3_coefficients_forward {
      theta2.so3_coefficient_forward()
    } else {
      theta2.so3_coefficients()
    }
    if split_so3_coefficients {
      let parts = coefficients.split_sections([1, 1])
      (parts[0], parts[1])
    } else {
      (col(coefficients, 0), col(coefficients, 1))
    }
  } else {
    let theta = theta2.affine(1.0, bias=1.0e-12).sqrt()
    let small = theta2.less(theta2.affine(0.0, bias=1.0e-8))
    let a = small.select_where(
      theta2.affine(-1.0 / 6.0, bias=1.0),
      theta.sin().div(theta),
    )
    let b = small.select_where(
      theta2.affine(-1.0 / 24.0, bias=0.5),
      theta.cos().affine(-1.0, bias=1.0).div(theta2.affine(1.0, bias=1.0e-12)),
    )
    (a, b)
  }
  let k = if fused_skew {
    v.fused_skew()
  } else if compact_skew {
    v.compact_skew()
  } else {
    skew(backend, v, detached_constants~)
  }
  if fused_so3_tail {
    guard detached_constants else {
      fail("fused SO3 tail requires detached constants")
    }
    return k.so3_tail(k.matmul(k), a, b)
  }
  // SMC builds skew zeros and the identity without autograd (zeros_like/eye).
  // Keep identical forward arithmetic while removing artificial zero VJPs.
  let source = if detached_constants { v.stop_gradient() } else { v }
  let zero = col(source, 0).affine(0.0)
  let one = zero.affine(0.0, bias=1.0)
  mat(backend, [one, zero, zero, zero, one, zero, zero, zero, one])
  .add(k.mul(a.reshape([-1, 1, 1])))
  .add(k.matmul(k).mul(b.reshape([-1, 1, 1])))
}

///|
pub fn so3_log(
  backend : @tensor.Backend,
  r : @tensor.Tensor,
) -> @tensor.Tensor raise {
  let q = mat_to_quat(backend, r)
  let v = q.narrow(1, 1, 3)
  // Clamping the unused large-angle branch also prevents 0 * NaN in autograd.
  let n = v.square().sum_dim(1, keepdim=true).clamp(1.0e-24, 1.0e30).sqrt()
  let w = col(q, 0)
  let small = n.less(n.affine(0.0, bias=1.0e-6))
  let scale = small.select_where(
    w.affine(0.0, bias=2.0).div(w.clamp(1.0e-6, 1.0e30)),
    n.atan2(w).affine(2.0).div(n.affine(1.0, bias=1.0e-12)),
  )
  v.mul(scale)
}

///|
pub(all) enum RotationErrorMode {
  GenCoordTraceAcos
  QuaternionLog
  TraceAcos
  GeodesicSquared
} derive(Debug, Eq, ToJson, FromJson)

///|
fn angle_square(
  backend : @tensor.Backend,
  a : @tensor.Tensor,
  b : @tensor.Tensor,
  mode~ : RotationErrorMode = QuaternionLog,
) -> @tensor.Tensor raise {
  match mode {
    GeodesicSquared => {
      let q = mat_to_quat(backend, a.matmul(tr(b)))
      let u = q.narrow(1, 1, 3).square().sum_dim(1, keepdim=true)
      let small = u
        .mul(u.affine(1.0 / 3.0, bias=1.0).add(u.square().affine(8.0 / 45.0)))
        .affine(4.0)
      let regular = u
        .clamp(1.0e-12, 1.0e30)
        .sqrt()
        .atan2(col(q, 0).abs())
        .square()
        .affine(4.0)
      u
      .less(u.stop_gradient().affine(0.0, bias=1.0e-8))
      .select_where(small, regular)
    }
    QuaternionLog =>
      so3_log(backend, a.matmul(tr(b))).square().sum_dim(1, keepdim=true)
    TraceAcos | GenCoordTraceAcos => {
      let eps = if mode == GenCoordTraceAcos { 1.0e-7 } else { 1.0e-6 }
      // Match smc/rotations.py::rot_angle_sq, including the clamp derivative.
      // One reduction over all nine products, not two nested reductions.
      a
      .mul(b)
      .reshape([-1, 9])
      .sum_dim(1, keepdim=true)
      .affine(1.0, bias=-1.0)
      .affine(0.5)
      .clamp(-1.0 + eps, 1.0 - eps)
      .acos()
      .square()
    }
  }
}

///|
fn axis_angle(
  backend : @tensor.Backend,
  axis : Array[Double],
  angle : @tensor.Tensor,
) -> @tensor.Tensor raise {
  let x = axis[0]
  let y = axis[1]
  let z = axis[2]
  let c = angle.cos()
  let s = angle.sin()
  let k = c.affine(-1.0, bias=1.0)
  mat(backend, [
    k.affine(x * x).add(c),
    k.affine(x * y).sub(s.affine(z)),
    k.affine(x * z).add(s.affine(y)),
    k.affine(y * x).add(s.affine(z)),
    k.affine(y * y).add(c),
    k.affine(y * z).sub(s.affine(x)),
    k.affine(z * x).sub(s.affine(y)),
    k.affine(z * y).add(s.affine(x)),
    k.affine(z * z).add(c),
  ])
}
