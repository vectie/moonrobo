///|
/// Explicit commissioning of an unchanged raw pose, not an encoder-zero
/// calibration or permission to move a leg. Default powered admission is strict.
pub(all) struct CurrentPoseProfile {
  format : String
  scope : String
  expected_knee_raw_rad : Double
  evidence_sha256 : String
} derive(FromJson, ToJson)

///|
pub extend CurrentPoseProfile with @json.FromJson::{from_json}

///|
pub extend CurrentPoseProfile with @json.ToJson::{to_json}

///|
pub fn CurrentPoseProfile::validate_baseline(
  self : Self,
  positions : ArrayView[Double],
) -> Unit raise {
  guard self.format == "moonrobo.e1-current-pose-commissioning.v1" &&
    self.scope == "unchanged-raw-hold-and-elbows-only" &&
    self.evidence_sha256.length() == 64 &&
    self.evidence_sha256
    .iter()
    .all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) &&
    self.expected_knee_raw_rad - self.expected_knee_raw_rad == 0.0 &&
    self.expected_knee_raw_rad >= -0.017453292519943295 &&
    self.expected_knee_raw_rad < 0.0 &&
    positions.length() == 24 &&
    positions.all(x => x - x == 0.0) else {
    fail("invalid measured current-pose commissioning profile")
  }
  // Only the captured, sub-degree right-knee zero discrepancy is admitted.
  // A different current reading requires reassessment, never silent clipping.
  guard positions[19] == self.expected_knee_raw_rad else {
    fail("current knee differs from commissioned raw hold")
  }
  for slot in 0..<24 {
    if @elbow.leg_slot(slot) &&
      slot != 19 &&
      !@elbow.leg_position_in_range(slot, positions[slot]) {
      fail("uncommissioned leg range discrepancy at slot " + slot.to_string())
    }
  }
}
