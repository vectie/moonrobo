///|
/// Metadata/array preparation only, with no filesystem/SDK/GPU operations.
/// This function computes real FK/index/inertial arrays when explicitly called;
/// typechecking it performs no numerical work.
pub fn prepare_from_receipt(request : PrepareRequest) -> PreparedArrays raise {
  guard request.placements.length() == request.num_envs else {
    fail("one explicit rigid placement is required for each requested world")
  }
  let plan = @scene.g1_plan(
    request.usd_receipt,
    request.num_envs,
    request.self_collisions,
  )
  let worlds : Array[WorldPlacement] = request.placements.map(p => {
    transform: frame(p.position, p.quaternion_wxyz),
  })
  prepare(plan, worlds)
}
