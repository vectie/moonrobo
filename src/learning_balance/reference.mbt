///|
pub fn encode_goal(
  state : Array[Double],
  positions : Array[Array[Double]],
  rotations : Array[Array[Double]],
  q_indices : Array[Int32],
  v_indices : Array[Int32],
  nq : Int32,
  root : Int32,
) -> Array[Double] {
  let r = rotations[root]
  let p = positions[root]
  let inverse = transpose(r)
  let out = q_indices.map(fn(i) { state[i] })
  for i in v_indices {
    out.push(state[nq + i])
  }
  for j in 0..<3 {
    out.push(-r[6 + j])
  }
  out.push(p[2])
  let local_velocity = matvec(inverse, [state[nq], state[nq + 1], state[nq + 2]])
  for x in local_velocity {
    out.push(x)
  }
  for j in 3..<6 {
    out.push(state[nq + j])
  }
  for position in positions {
    let relative = matvec(
      inverse,
      Array::makei(3, fn(j) { position[j] - p[j] }),
    )
    for x in relative {
      out.push(x)
    }
  }
  for rotation in rotations {
    let relative = matmul(inverse, rotation)
    for column in 0..<2 {
      for row in 0..<3 {
        out.push(relative[row * 3 + column])
      }
    }
  }
  out
}

///|
pub(all) struct FullBodyReference {
  goals : Array[Array[Double]]
  dt : Double
} derive(Debug)

///|
pub fn FullBodyReference::new(
  goals : Array[Array[Double]],
  timestamps : Array[Double],
  controls : Array[Array[Double]],
  dt : Double,
) -> FullBodyReference {
  guard goals.length() >= 2 &&
    controls.length() + 1 == goals.length() &&
    timestamps.length() == goals.length() else {
    abort("reference needs T controls and T+1 frames")
  }
  guard dt > 0.0 else { abort("positive reference cadence required") }
  for i in 1..<timestamps.length() {
    guard (timestamps[i] - timestamps[i - 1] - dt).abs() <=
      1.0e-10 + 1.0e-8 * dt else {
      abort("reference cadence mismatch")
    }
    guard goals[i].length() == goals[0].length() else {
      abort("inconsistent reference goal layout")
    }
  }
  for row in goals {
    for x in row {
      guard finite(x) else { abort("nonfinite reference goal") }
    }
  }
  { goals, dt, }
}

///|
pub fn FullBodyReference::preview(
  self : FullBodyReference,
  step : Int32,
  length~ : Int32 = 10,
) -> (Array[Array[Double]], Array[Bool]) {
  let steps = self.goals.length() - 1
  guard step >= 0 && step < steps && length > 0 else {
    abort("invalid preview index or length")
  }
  let valid = Array::makei(length, fn(i) { step + i + 1 <= steps })
  let values = Array::makei(length, fn(i) {
    self.goals[if step + i + 1 > steps { steps } else { step + i + 1 }].copy()
  })
  (values, valid)
}

///|
pub(all) struct TrackingTrial {
  case_id : String
  origin : Int32
  failed : Bool
  simulated_seconds : Double
  requested_seconds : Double
  metrics : Map[String, Double]
} derive(Debug)

///|
pub fn assess_tracking_quality(
  trials : Array[TrackingTrial],
  expected : Array[(String, Int32)],
  limits : Map[String, Double],
) -> (Bool, Array[Array[String]]) {
  let seen : Map[(String, Int32), Bool] = {}
  let failures : Array[Array[String]] = []
  let mut complete = trials.length() == expected.length()
  for t in trials {
    let key = (t.case_id, t.origin)
    if seen.contains(key) || !expected.contains(key) {
      complete = false
    }
    seen[key] = true
    let reasons : Array[String] = []
    if t.failed || (t.simulated_seconds - t.requested_seconds).abs() > 1.0e-10 {
      reasons.push("incomplete-trajectory")
    }
    for metric, limit in limits {
      match t.metrics.get(metric) {
        Some(value) =>
          if !finite(value) || value > limit {
            reasons.push(metric)
          }
        None => reasons.push(metric)
      }
    }
    failures.push(reasons)
  }
  let mut passed = complete
  for row in failures {
    if !row.is_empty() {
      passed = false
    }
  }
  (passed, failures)
}

///|
fn finite(x : Double) -> Bool {
  x == x && x - x == 0.0
}
