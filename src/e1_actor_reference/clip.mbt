///|
priv struct StoredFrame {
  goals : Array[Double]
  body_to_world : Array[Double]
} derive(FromJson)

///|
priv struct Record {
  format : String
  profile_id : String
  joints : Array[String]
  reference_id : String
  control_dt_ms : Int32
  goal_layout : String
  frames : Array[StoredFrame]
} derive(FromJson)

///|
/// Prepared raw goals and reference attitude in the actor's calibrated world.
/// The last stored frame reports completion; earlier frames drive inference.
pub(all) struct Frame {
  goals : Array[Double]
  body_to_world : Array[Double]
  complete : Bool
}

///|
/// Deployment-only prepared motion. Arrays are private and validated at load;
/// sampling copies the selected frame without importing training geometry.
pub struct Clip {
  priv id : String
  priv frames : Array[StoredFrame]
}

///|
fn finite(value : Double) -> Bool {
  value == value && value - value == 0.0
}

///|
fn rotation(matrix : Array[Double]) -> Bool {
  if matrix.length() != 9 || !matrix.all(finite) {
    return false
  }
  for r in 0..<3 {
    for c in 0..<3 {
      let dot = matrix[r * 3] * matrix[c * 3] +
        matrix[r * 3 + 1] * matrix[c * 3 + 1] +
        matrix[r * 3 + 2] * matrix[c * 3 + 2]
      if (dot - (if r == c { 1.0 } else { 0.0 })).abs() > 1.0e-6 {
        return false
      }
    }
  }
  let determinant = matrix[0] * (matrix[4] * matrix[8] - matrix[5] * matrix[7]) -
    matrix[1] * (matrix[3] * matrix[8] - matrix[5] * matrix[6]) +
    matrix[2] * (matrix[3] * matrix[7] - matrix[4] * matrix[6])
  (determinant - 1.0).abs() <= 1.0e-6
}

///|
pub fn Clip::parse(bundle : @actor.Bundle, value : Json) -> Self raise {
  let record : Record = @json.from_json(value)
  guard record.format == "moonrobo.e1-actor-reference.v1" &&
    record.profile_id == bundle.profile_id() &&
    record.joints.length() == bundle.joints().length() &&
    record.reference_id != "" &&
    record.control_dt_ms == 20 &&
    record.goal_layout == "aligned.preview73.v1" &&
    record.frames.length() >= 2 else {
    fail("E1 prepared reference contract differs")
  }
  for i, name in record.joints {
    guard name == bundle.joints()[i] else {
      fail("E1 reference joint order differs")
    }
  }
  for frame in record.frames {
    guard frame.goals.length() == bundle.goal_width() &&
      frame.goals.all(finite) &&
      rotation(frame.body_to_world) else {
      fail("invalid E1 prepared reference frame")
    }
  }
  { id: record.reference_id, frames: record.frames, }
}

///|
pub async fn Clip::read(bundle : @actor.Bundle, path : String) -> Self {
  Clip::parse(bundle, @fs.read_file(path).json())
}

///|
pub fn Clip::reference_id(self : Self) -> String {
  self.id
}

///|
pub fn Clip::frame_count(self : Self) -> Int32 {
  self.frames.length()
}

///|
/// Time to the terminal frame at20ms cadence, not a task deadline budget.
/// The host allows separate headroom for startup and terminal capture/checks.
pub fn Clip::duration_ms(self : Self) -> Int64 {
  (self.frames.length() - 1).to_int64() * 20L
}

///|
/// No implicit skill-parameter transforms or looping. The caller schedules one
/// step per control tick; completion still requires the runner's fresh capture.
pub fn Clip::frame(
  self : Self,
  execution : @skills.Execution,
  step : Int32,
) -> Frame raise {
  guard execution.reference_id == self.id &&
    execution.parameters.is_empty() &&
    step >= 0 else {
    fail("prepared reference selection, parameters or step differ")
  }
  let last = self.frames.length() - 1
  let frame = self.frames[step.min(last)]
  {
    goals: frame.goals.copy(),
    body_to_world: frame.body_to_world.copy(),
    complete: step >= last,
  }
}
