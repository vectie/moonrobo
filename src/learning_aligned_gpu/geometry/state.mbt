///|
pub(all) struct State {
  p : @tensor.Tensor
  rotation : @tensor.Tensor
  v : @tensor.Tensor
  w : @tensor.Tensor
  q : @tensor.Tensor
  qd : @tensor.Tensor
}

///|
/// Replay layout: p[3], quaternion WXYZ[4], v[3], w[3], q[29], qd[29].
/// BONES source CSV XYZW must be converted by the motion loader before this boundary.
pub fn State::from_flat71(
  backend : @tensor.Backend,
  flat : @tensor.Tensor,
) -> State raise {
  let shape = flat.shape()
  guard shape.length() == 2 && shape[1] == 71 else {
    fail("state requires [B,71] WXYZ replay tensor")
  }
  {
    p: flat.narrow(1, 0, 3),
    rotation: quat_to_mat(backend, flat.narrow(1, 3, 4)),
    v: flat.narrow(1, 7, 3),
    w: flat.narrow(1, 10, 3),
    q: flat.narrow(1, 13, 29),
    qd: flat.narrow(1, 42, 29),
  }
}

///|
pub fn State::flatten71(
  self : State,
  backend : @tensor.Backend,
) -> @tensor.Tensor raise {
  columns(backend, [
    self.p,
    mat_to_quat(backend, self.rotation),
    self.v,
    self.w,
    self.q,
    self.qd,
  ])
}

///|
pub fn invariant_features(
  backend : @tensor.Backend,
  s : State,
  heading_mode~ : HeadingMode = StableFallback,
  compact_heading~ : Bool = false,
  source_order~ : Bool = false,
) -> @tensor.Tensor raise {
  if !source_order {
    return columns(backend, [
      col(s.p, 2),
      mat_to_6d(
        tr(
          yaw_mat(
            backend,
            s.rotation,
            mode=heading_mode,
            compact=compact_heading,
          ),
        ).matmul(s.rotation),
      ),
      mv(tr(s.rotation), s.v),
      mv(tr(s.rotation), s.w),
      s.q,
      s.qd,
    ])
  }
  let heading = yaw_mat(
    backend,
    s.rotation,
    mode=heading_mode,
    compact=compact_heading,
    source_order~,
  )
  let rt = tr(s.rotation)
  columns(backend, [
    col(s.p, 2),
    mat_to_6d(tr(heading).matmul(s.rotation)),
    mv(rt, s.v),
    mv(rt, s.w),
    s.q,
    s.qd,
  ])
}

///|
pub fn normalize_xi(
  backend : @tensor.Backend,
  xi : @tensor.Tensor,
) -> @tensor.Tensor raise {
  columns(backend, [
    col(xi, 0).affine(1.0 / 0.45, bias=-0.75 / 0.45),
    xi.narrow(1, 1, 29).affine(100.0),
    xi.narrow(1, 30, 3).affine(20.0),
  ])
}

///|
pub fn world_inputs(
  backend : @tensor.Backend,
  s : State,
  action : @tensor.Tensor,
  xi_n : @tensor.Tensor,
  heading_mode~ : HeadingMode = StableFallback,
  compact_heading~ : Bool = false,
  source_order~ : Bool = false,
) -> @tensor.Tensor raise {
  columns(backend, [
    invariant_features(
      backend,
      s,
      heading_mode~,
      compact_heading~,
      source_order~,
    ),
    action,
    xi_n,
  ])
}

///|
pub fn world_targets(
  backend : @tensor.Backend,
  s : State,
  next : State,
  heading_mode~ : HeadingMode = StableFallback,
  compact_heading~ : Bool = false,
  smc_rotation~ : Bool = false,
) -> @tensor.Tensor raise {
  let rt = tr(s.rotation)
  columns(backend, [
    mv(
      tr(
        yaw_mat(backend, s.rotation, mode=heading_mode, compact=compact_heading),
      ),
      next.p.sub(s.p),
    ),
    if smc_rotation {
      rt.matmul(next.rotation).rotation_vector_smc()
    } else {
      so3_log(backend, rt.matmul(next.rotation))
    },
    mv(rt, next.v.sub(s.v)),
    mv(rt, next.w.sub(s.w)),
    next.q.sub(s.q),
    next.qd.sub(s.qd),
  ])
}

///|
pub fn state_error(
  backend : @tensor.Backend,
  predicted : State,
  target : State,
  heading_mode~ : HeadingMode = StableFallback,
  compact_heading~ : Bool = false,
  smc_rotation~ : Bool = false,
) -> @tensor.Tensor raise {
  world_targets(
    backend,
    target,
    predicted,
    heading_mode~,
    compact_heading~,
    smc_rotation~,
  )
}

///|
pub fn world_integrate(
  backend : @tensor.Backend,
  s : State,
  delta : @tensor.Tensor,
  heading_mode~ : HeadingMode = StableFallback,
  compact_heading~ : Bool = false,
  detached_constants~ : Bool = false,
  compact_skew~ : Bool = false,
  fused_skew~ : Bool = false,
  fused_so3_tail~ : Bool = false,
  fused_so3_coefficients~ : Bool = false,
  fused_so3_coefficients_forward~ : Bool = false,
  fused_so3_coefficients_full~ : Bool = false,
  split_so3_coefficients~ : Bool = false,
  split_delta~ : Bool = false,
  source_order~ : Bool = false,
) -> State raise {
  let heading = if source_order {
    Some(yaw_mat(backend, s.rotation, mode=heading_mode, source_order=true))
  } else {
    None
  }
  let sections = if split_delta {
    Some(delta.split_sections([3, 3, 3, 3, 29, 29]))
  } else {
    None
  }
  let part = (offset : Int32, count : Int32, i : Int32) => {
    match sections {
      Some(parts) => parts[i]
      None => delta.narrow(1, offset, count)
    }
  }
  {
    p: s.p.add(
      mv(
        match heading {
          Some(value) => value
          None =>
            yaw_mat(
              backend,
              s.rotation,
              mode=heading_mode,
              compact=compact_heading,
            )
        },
        part(0, 3, 0),
      ),
    ),
    rotation: s.rotation.matmul(
      if source_order {
        part(3, 3, 1).rotation_matrix_smc()
      } else {
        so3_exp(
          backend,
          part(3, 3, 1),
          detached_constants~,
          compact_skew~,
          fused_skew~,
          fused_so3_tail~,
          fused_so3_coefficients~,
          fused_so3_coefficients_forward~,
          fused_so3_coefficients_full~,
          split_so3_coefficients~,
        )
      },
    ),
    v: s.v.add(mv(s.rotation, part(6, 3, 2))),
    w: s.w.add(mv(s.rotation, part(9, 3, 3))),
    q: s.q.add(part(12, 29, 4)),
    qd: s.qd.add(part(41, 29, 5)),
  }
}
