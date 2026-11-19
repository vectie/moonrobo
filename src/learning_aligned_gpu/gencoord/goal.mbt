///|
/// Inclusive final frame as stored in MoonRobo's MotionLibrary.
pub fn preview_frames(frame : Int32, last : Int32) -> Array[Int32] raise {
  guard frame >= 0 && frame <= last else { fail("invalid motion frame") }
  Array::makei(10, i => frame + (5 * i).min(last - frame))
}

///|
pub(all) struct Goals {
  actor : @tensor.Tensor
  world : @tensor.Tensor
}

///|
/// Cached window entries use MoonRobo's replay order. Their relative anchor
/// is rebuilt from the live (or imagined) robot pose at every step.
pub fn GenState::goals(
  self : GenState,
  b : @tensor.Backend,
  window : @tensor.Tensor,
) -> Goals raise {
  guard window.shape() is [n, 10, 71] else {
    fail("GenCoord needs ten 71D preview rows per example")
  }
  let rows = window.reshape([-1, 71])
  let content = rows.narrow(1, 13, 58).reshape([n, 580])
  let r = @geometry.quat_to_mat(b, self.quat)
    .transpose_dims(1, 2)
    .reshape([n, 1, 3, 3])
  let positions = window.narrow(2, 0, 3).sub(self.position.reshape([n, 1, 3]))
  let rel_pos = r.matmul(positions.reshape([n, 10, 3, 1])).reshape([n, 30])
  let targets = @geometry.quat_to_mat(b, rows.narrow(1, 3, 4)).reshape([
    n, 10, 3, 3,
  ])
  let rel_ori = r.matmul(targets).narrow(3, 0, 2).reshape([n, 60])
  {
    actor: b.concat([content, rel_ori], axis=1),
    world: b.concat([content, rel_pos, rel_ori], axis=1),
  }
}
