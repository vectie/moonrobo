///|
/// Validate the reference catalog before collecting or allocating a learner.
/// H transitions require H+1 reference states. Short clips remain in the catalog
/// and retain their reset probability when at least one clip can serve actor BPTT.
pub fn MotionLibrary::require_actor_horizon(
  self : MotionLibrary,
  horizon : Int32,
) -> String raise {
  guard horizon > 0 && self.clip_start.length() == self.clip_end.length() else {
    fail("invalid actor horizon or reference clip boundaries")
  }
  let mut eligible = 0
  let mut longest = 0
  for i, start in self.clip_start {
    let span = self.clip_end[i] - start
    guard span >= 0 else { fail("invalid reference clip span") }
    longest = longest.max(span)
    if span >= horizon {
      eligible += 1
    }
  }
  let summary = "catalog_clips=\{self.clip_start.length()}, eligible_clips=\{eligible}, longest_clip_steps=\{longest}, horizon=\{horizon}"
  guard eligible > 0 else {
    fail(
      "reference catalog has no complete imagination horizon (H+1 states required); " +
      summary,
    )
  }
  summary
}
