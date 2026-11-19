///|
/// 60 s lift, 2 s raised hold, four 16 s strokes, 45 s return.
pub const RAISED_DRUM_FRAMES : Int32 = 8551

///|
/// Absolute elbow angles in degrees. A stroke drops from -90 to -60 and back.
pub fn raised_drum_targets(
  frame : Int32,
  left_start : Double,
  right_start : Double,
) -> (Double, Double) raise {
  guard frame >= 0 && frame < RAISED_DRUM_FRAMES else {
    fail("raised drum frame outside reference")
  }
  if frame == RAISED_DRUM_FRAMES - 1 {
    return (left_start, right_start)
  }
  if frame <= 3000 {
    let blend = (1.0 - @math.cos(@math.PI * frame.to_double() / 3000.0)) / 2.0
    return (
      left_start + (-90.0 - left_start) * blend,
      right_start + (-90.0 - right_start) * blend,
    )
  }
  if frame < 3100 {
    return (-90.0, -90.0)
  }
  if frame < 6300 {
    let stroke = (frame - 3100) / 800
    let drop = fold_offset(30.0, (frame - 3100) % 800, frames=801)
    return if stroke % 2 == 0 {
      (-90.0 + drop, -90.0)
    } else {
      (-90.0, -90.0 + drop)
    }
  }
  let blend = (1.0 - @math.cos(@math.PI * (frame - 6300).to_double() / 2250.0)) /
    2.0
  (-90.0 + (left_start + 90.0) * blend, -90.0 + (right_start + 90.0) * blend)
}

///|
/// Raised alternating strokes, paced by feedback within the existing following
/// tolerance. A held reference still requires fresh, healthy feedback each tick.
pub fn DrumPath::raised(hold : ArrayView[@low.MotorCommand]) -> DrumPath raise {
  guard hold.length() == 24 else { fail("24-slot raised drum hold required") }
  let targets = Array::makei(RAISED_DRUM_FRAMES, i => {
    let (left, right) = raised_drum_targets(
      i,
      hold[3].position / RAD,
      hold[14].position / RAD,
    )
    (left * RAD, right * RAD)
  })
  // Preserve the exact captured endpoints, without round-trip unit conversion.
  targets[0] = (hold[3].position, hold[14].position)
  targets[RAISED_DRUM_FRAMES - 1] = targets[0]
  drum_path(hold, targets, true)
}

///|
/// Number of reference frames accepted so far; wall-clock ticks may be greater
/// when a paced reference waits for the measured elbows to catch up.
pub fn DrumPath::frame_index(self : DrumPath) -> Int32 {
  self.step
}
