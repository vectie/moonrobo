///|
/// Rebind an execution option without copying kinematic tensor storage. The
/// learner uses this to honor its execution settings for every constructor path.
pub fn Context::with_body_orientation_batched(
  self : Context,
  enabled : Bool,
) -> Context raise {
  guard !enabled || self.kin.tracked.length() <= 64 else {
    fail("batched body orientation exceeds the admitted 64 tracked-body bound")
  }
  { ..self, body_orientation_batched: enabled, }
}

///|
/// Flatten [batch, body, 3, 3] only after shared yaw alignment. Each flattened
/// row uses the explicitly selected rotation error, including its clamp gradient.
fn Context::batched_body_orientation(
  self : Context,
  dr : @tensor.Tensor,
  bodies : Array[BodyState],
  refs : Array[BodyState],
) -> @tensor.Tensor raise {
  let count = bodies.length()
  guard count > 0 && count <= 64 && refs.length() == count else {
    fail("invalid batched body orientation contract")
  }
  let rotations = self.backend.stack(bodies.map(b => b.rotation), axis=1)
  let references = self.backend.stack(refs.map(b => b.rotation), axis=1)
  let targets = dr.reshape([-1, 1, 3, 3]).matmul(references)
  angle_square(
    self.backend,
    targets.reshape([-1, 3, 3]),
    rotations.reshape([-1, 3, 3]),
    mode=self.rotation_error_mode,
  )
  .reshape([-1, count])
  .mean_dim(1, keepdim=true)
}

///|
/// Select SMC's clamped trace-acos reward or the preserved quaternion-log path.
/// This affects reward derivatives; callers must record it in checkpoints.
pub fn Context::with_rotation_error_mode(
  self : Context,
  mode : RotationErrorMode,
) -> Context {
  { ..self, rotation_error_mode: mode, }
}
