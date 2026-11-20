///|
/// First typing-reference elbow pose: 60 s entry, 2 s hold, 60 s return.
/// This commissions only the previously exercised pitch motors, not the actor
/// or the full typing gesture. Angles are frame zero of the hash-verified
/// bones-230711__cellphone_typing_stand_one_hand_idle_R_001__A423_M reference.
pub const TYPING_ELBOW_FRAMES : Int32 = 6101

///|
pub const TYPING_LEFT_RAD : Double = -1.4477981791899937

///|
pub const TYPING_RIGHT_RAD : Double = -0.5434064639344343

///|
fn minimum_jerk(u : Double) -> Double {
  u * u * u * (10.0 + u * (-15.0 + 6.0 * u))
}

///|
pub fn typing_elbow_targets(
  frame : Int32,
  left_start : Double,
  right_start : Double,
) -> (Double, Double) raise {
  guard frame >= 0 &&
    frame < TYPING_ELBOW_FRAMES &&
    finite(left_start) &&
    finite(right_start) else {
    fail("invalid typing elbow frame")
  }
  if frame == 0 || frame == TYPING_ELBOW_FRAMES - 1 {
    return (left_start, right_start)
  }
  if frame >= 3000 && frame <= 3100 {
    return (TYPING_LEFT_RAD, TYPING_RIGHT_RAD)
  }
  let weight = if frame < 3000 {
    minimum_jerk(frame.to_double() / 3000.0)
  } else {
    1.0 - minimum_jerk((frame - 3100).to_double() / 3000.0)
  }
  (
    left_start + (TYPING_LEFT_RAD - left_start) * weight,
    right_start + (TYPING_RIGHT_RAD - right_start) * weight,
  )
}

///|
/// Preserve all 22 non-elbow command records and the established paced
/// telemetry/following checks. No transport, SDK or mode is opened here.
pub fn DrumPath::typing_pose(
  hold : ArrayView[@low.MotorCommand],
) -> DrumPath raise {
  guard hold.length() == 24 else { fail("24-slot typing hold required") }
  let targets = Array::makei(TYPING_ELBOW_FRAMES, i => {
    typing_elbow_targets(i, hold[3].position, hold[14].position)
  })
  drum_path(hold, targets, true)
}
