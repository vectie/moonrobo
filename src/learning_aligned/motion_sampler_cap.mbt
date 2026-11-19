///|
fn validate_motion_sampler_cap(cap : Int32?) -> Unit raise {
  if cap is Some(value) {
    guard value >= 1 && value <= 43149672 else {
      fail("motion sampler bin cap must be within 1..43149672")
    }
  }
}

///|
/// Validate the entire next clip before creating any of its ResetBin objects.
/// Counts use the same terminal-bin formula as the uncapped loader.
fn checked_motion_bin_count(
  existing : Int32,
  frames : Int32,
  cap : Int32?,
) -> Int32 raise {
  validate_motion_sampler_cap(cap)
  guard existing >= 0 && frames >= 2 else {
    fail("invalid motion bin dimensions")
  }
  let count = (frames - 2) / 50 + 1
  if cap is Some(limit) {
    guard existing <= limit && count <= limit - existing else {
      fail("motion sampler bin capacity exceeded before reset-bin construction")
    }
  }
  count
}
