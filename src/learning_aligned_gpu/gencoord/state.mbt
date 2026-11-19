///|
/// The auxiliary state is world xyz and WXYZ. The 68 policy features retain
/// body-frame velocities across imagined steps, as in GenCoordRepresentation.
pub(all) struct GenState {
  position : @tensor.Tensor
  quat : @tensor.Tensor
  reduced : @tensor.Tensor
}

///|
fn rotate(r : @tensor.Tensor, v : @tensor.Tensor) -> @tensor.Tensor raise {
  r.matmul(v.reshape([-1, 3, 1])).reshape([-1, 3])
}

///|
fn body_state(
  b : @tensor.Backend,
  p : @tensor.Tensor,
  r : @tensor.Tensor,
  v : @tensor.Tensor,
  w : @tensor.Tensor,
  q : @tensor.Tensor,
  qd : @tensor.Tensor,
) -> @tensor.Tensor raise {
  let inv = r.transpose_dims(1, 2)
  let gravity = r.narrow(1, 2, 1).reshape([-1, 3]).affine(-1.0)
  b.concat(
    [p.narrow(1, 2, 1), gravity, rotate(inv, v), rotate(inv, w), q, qd],
    axis=1,
  )
}

///|
/// MoonRobo replay layout p, quat, v_world, w_world, joints, joint velocities.
pub fn GenState::from_replay(
  b : @tensor.Backend,
  flat : @tensor.Tensor,
) -> GenState raise {
  guard flat.shape() is [_, 71] else {
    fail("G1 replay rows must have width 71")
  }
  let position = flat.narrow(1, 0, 3)
  let quat = flat.narrow(1, 3, 4)
  let r = @geometry.quat_to_mat(b, quat)
  {
    position,
    quat,
    reduced: body_state(
      b,
      position,
      r,
      flat.narrow(1, 7, 3),
      flat.narrow(1, 10, 3),
      flat.narrow(1, 13, 29),
      flat.narrow(1, 42, 29),
    ),
  }
}

///|
pub fn GenState::geometry(
  self : GenState,
  b : @tensor.Backend,
) -> @geometry.State raise {
  let r = @geometry.quat_to_mat(b, self.quat)
  {
    p: self.position,
    rotation: r,
    v: rotate(r, self.reduced.narrow(1, 4, 3)),
    w: rotate(r, self.reduced.narrow(1, 7, 3)),
    q: self.reduced.narrow(1, 10, 29),
    qd: self.reduced.narrow(1, 39, 29),
  }
}

///|
/// Hamilton product of the world-frame incremental rotation with the old pose.
fn integrate_quat(
  b : @tensor.Backend,
  q : @tensor.Tensor,
  omega : @tensor.Tensor,
) -> @tensor.Tensor raise {
  let norm = omega
    .square()
    .sum_dim(1, keepdim=true)
    .affine(1.0, bias=1.0e-8)
    .sqrt()
  let dw = norm.affine(0.5).cos()
  let dv = norm.affine(0.5).sin().mul(omega.div(norm))
  let qw = q.narrow(1, 0, 1)
  let qv = q.narrow(1, 1, 3)
  let cross = dv.native_cross(qv)
  let product = b.concat(
    [
      dw.mul(qw).sub(dv.mul(qv).sum_dim(1, keepdim=true)),
      dw.mul(qv).add(qw.mul(dv)).add(cross),
    ],
    axis=1,
  )
  product.div(product.square().sum_dim(1, keepdim=true).sqrt())
}

///|
pub fn GenState::advance(
  self : GenState,
  b : @tensor.Backend,
  delta : @tensor.Tensor,
  dt~ : Double,
  decimation~ : Int32,
) -> GenState raise {
  guard decimation > 0 && dt > 0 && delta.shape() is [_, 35] else {
    fail("invalid GenCoord integration")
  }
  let c = (decimation.to_double() + 1.0) / (2.0 * decimation.to_double())
  let r = @geometry.quat_to_mat(b, self.quat)
  let v = self.reduced.narrow(1, 4, 3)
  let w = self.reduced.narrow(1, 7, 3)
  let q = self.reduced.narrow(1, 10, 29)
  let qd = self.reduced.narrow(1, 39, 29)
  let dv = delta.narrow(1, 0, 3)
  let dw = delta.narrow(1, 3, 3)
  let dqd = delta.narrow(1, 6, 29)
  let position = self.position.add(rotate(r, v.add(dv.affine(c))).affine(dt))
  let quat = integrate_quat(
    b,
    self.quat,
    rotate(r, w.add(dw.affine(c))).affine(dt),
  )
  {
    position,
    quat,
    reduced: body_state(
      b,
      position,
      @geometry.quat_to_mat(b, quat),
      rotate(r, v.add(dv)),
      rotate(r, w.add(dw)),
      q.add(qd.add(dqd.affine(c)).affine(dt)),
      qd.add(dqd),
    ),
  }
}

///|
/// Width-weighted Bryson loss on integrated states (3 position, 9 rotation,
/// 29 angle, 29 velocity channels); one mean over all samples and time steps.
pub fn GenState::fit_error(
  self : GenState,
  b : @tensor.Backend,
  target : GenState,
) -> @tensor.Tensor raise {
  let r = @geometry.quat_to_mat(b, self.quat)
  let rt = @geometry.quat_to_mat(b, target.quat)
  b
  .concat(
    [
      self.position.sub(target.position).affine(1.0 / 0.01),
      r.sub(rt).reshape([-1, 9]).affine(0.5.sqrt() / 0.02),
      self.reduced
      .narrow(1, 10, 29)
      .sub(target.reduced.narrow(1, 10, 29))
      .affine(1.0 / 0.1),
      self.reduced
      .narrow(1, 39, 29)
      .sub(target.reduced.narrow(1, 39, 29))
      .affine(1.0 / 3.14),
    ],
    axis=1,
  )
  .square()
  .mean()
}

///|
pub fn GenState::failure(
  self : GenState,
  b : @tensor.Backend,
  reference : @geometry.State,
  height~ : Double,
  tilt~ : Double,
  softness~ : Double = 0.05,
) -> @tensor.Tensor raise {
  guard height > 0.0 && tilt > 0.0 && softness > 0.0 else {
    fail("invalid soft termination thresholds")
  }
  let height_ratio = self.position
    .narrow(1, 2, 1)
    .sub(reference.p.narrow(1, 2, 1))
    .abs()
    .affine(1.0 / height)
  let tilt_ratio = @geometry.quat_to_mat(b, self.quat)
    .reshape([-1, 9])
    .narrow(1, 8, 1)
    .sub(reference.rotation.reshape([-1, 9]).narrow(1, 8, 1))
    .abs()
    .affine(1.0 / tilt)
  height_ratio
  .maximum(tilt_ratio)
  .affine(1.0 / softness, bias=-1.0 / softness)
  .sigmoid()
}
