///|
pub fn clip(value : Double, lower : Double, upper : Double) -> Double {
  @math.minimum(@math.maximum(value, lower), upper)
}

///|
pub(all) struct LearnedAnkleHead {
  nu : Int32
  indices : Array[Int32]
  lower : Array[Double]
  upper : Array[Double]
  bound : Double
  pose_rate : Bool
  mean : Array[Array[Double]]
  scale : Array[Array[Double]]
  weight : Array[Array[Double]]
} derive(Debug, ToJson, FromJson)

///|
pub fn LearnedAnkleHead::new(
  names : Array[String],
  lower : Array[Double],
  upper : Array[Double],
  bound~ : Double = 0.3,
  pose_rate~ : Bool = false,
) -> LearnedAnkleHead {
  let indices : Array[Int32] = []
  for side in ["left", "right"] {
    for axis in ["pitch", "roll"] {
      let name = side + "_ankle_" + axis + "_joint"
      let mut found = -1
      for i, n in names {
        if n == name {
          found = i
        }
      }
      guard found >= 0 else { abort("missing ankle joint") }
      indices.push(found)
    }
  }
  let dimensions = if pose_rate { 5 } else { 3 }
  {
    nu: names.length(),
    indices,
    lower: indices.map(fn(i) { lower[i] }),
    upper: indices.map(fn(i) { upper[i] }),
    bound,
    pose_rate,
    mean: Array::makei(4, fn(_) { Array::make(dimensions, 0.0) }),
    scale: Array::makei(4, fn(_) { Array::make(dimensions, 1.0) }),
    weight: Array::makei(4, fn(_) { Array::make(dimensions + 1, 0.0) }),
  }
}

///|
pub fn LearnedAnkleHead::inputs(
  self : LearnedAnkleHead,
  obs : Array[Double],
  features : Array[Double],
) -> Array[Array[Double]] {
  let gx = obs[2 * self.nu]
  let gy = obs[2 * self.nu + 1]
  let gz = obs[2 * self.nu + 2]
  let pitch = @math.atan2(gx, (gy * gy + gz * gz).sqrt())
  let roll = @math.atan2(-gy, -gz)
  Array::makei(4, fn(j) {
    let axis = j % 2
    let row = [
      features[axis],
      features[3 + axis],
      obs[self.nu + self.indices[j]],
    ]
    if self.pose_rate {
      row.push(if axis == 0 { pitch } else { roll })
      row.push(obs[2 * self.nu + 3 + (if axis == 0 { 1 } else { 0 })])
    }
    row
  })
}

///|
pub fn LearnedAnkleHead::residual(
  self : LearnedAnkleHead,
  inputs : Array[Array[Double]],
) -> Array[Double] {
  Array::makei(4, fn(j) {
    let n = inputs[j].length()
    let mut y = self.weight[j][n]
    for k in 0..<n {
      y += (inputs[j][k] - self.mean[j][k]) /
        self.scale[j][k] *
        self.weight[j][k]
    }
    y
  })
}

///|
pub fn LearnedAnkleHead::predict(
  self : LearnedAnkleHead,
  obs : Array[Double],
  goal : Array[Double],
  features : Array[Double],
) -> Array[Double] {
  let residual = self.residual(self.inputs(obs, features))
  Array::makei(4, fn(j) {
    clip(
      goal[self.indices[j]] + clip(residual[j], -self.bound, self.bound),
      self.lower[j],
      self.upper[j],
    )
  })
}

///|
/// Canonical shared column-pivoted Householder QR. The learning boundary keeps
/// the historical full-column-rank requirement and one-vector result shape.
/// Parameter/checkpoint ordering is unchanged; numerical reduction and rank
/// decisions differ from the archived twice-orthogonalized Gram-Schmidt code.
pub fn least_squares(
  matrix : Array[Array[Double]],
  target : Array[Double],
) -> Array[Double] {
  guard !matrix.is_empty() && matrix.length() == target.length() else {
    abort("empty or misaligned OLS")
  }
  let columns = matrix[0].length()
  guard matrix.length() >= columns else { abort("OLS design is not full rank") }
  let fit = @linalg.least_squares(
    matrix,
    target.map(fn(x) { [x] }),
    rcond=1.0e-12,
  ) catch {
    _ => abort("invalid OLS design or nonfinite least-squares result")
  }
  guard fit.rank == columns else { abort("OLS design is not full rank") }
  fit.solution.map(fn(row) { row[0] })
}

///|
pub(all) struct FitReport {
  uncensored_points : Int32
  rank : Int32
  rmse : Double
  raw_coefficients : Array[Double]
} derive(Debug, ToJson, FromJson)

///|
pub fn LearnedAnkleHead::fit(
  self : LearnedAnkleHead,
  inputs : Array[Array[Array[Double]]],
  goals : Array[Array[Double]],
  targets : Array[Array[Double]],
  margin~ : Double = 2.0e-6,
) -> Array[FitReport] {
  let n = inputs.length()
  guard n > 0 && goals.length() == n && targets.length() == n else {
    abort("invalid training points")
  }
  let dimensions = inputs[0][0].length()
  for j in 0..<4 {
    for k in 0..<dimensions {
      let mut mean = 0.0
      for row in inputs {
        mean += row[j][k] / n.to_double()
      }
      let mut variance = 0.0
      for row in inputs {
        let d = row[j][k] - mean
        variance += d * d / n.to_double()
      }
      self.mean[j][k] = mean
      self.scale[j][k] = @math.maximum(variance.sqrt(), 1.0e-6)
    }
  }
  let reports : Array[FitReport] = []
  for j in 0..<4 {
    let matrix : Array[Array[Double]] = []
    let target : Array[Double] = []
    for i in 0..<n {
      let y = targets[i][self.indices[j]]
      let residual = y - goals[i][self.indices[j]]
      if residual.abs() < self.bound - margin &&
        y > self.lower[j] + margin &&
        y < self.upper[j] - margin {
        let row = Array::makei(dimensions, fn(k) {
          (inputs[i][j][k] - self.mean[j][k]) / self.scale[j][k]
        })
        row.push(1.0)
        matrix.push(row)
        target.push(residual)
      }
    }
    let solution = least_squares(matrix, target)
    for k in 0..<=dimensions {
      self.weight[j][k] = solution[k]
    }
    let mut squared = 0.0
    for i in 0..<matrix.length() {
      let d = dot(matrix[i], solution) - target[i]
      squared += d * d
    }
    let raw = Array::makei(dimensions, fn(k) { solution[k] / self.scale[j][k] })
    let mut bias = solution[dimensions]
    for k in 0..<dimensions {
      bias -= raw[k] * self.mean[j][k]
    }
    raw.push(bias)
    reports.push({
      uncensored_points: target.length(),
      rank: dimensions + 1,
      rmse: (squared / target.length().to_double()).sqrt(),
      raw_coefficients: raw,
    })
  }
  reports
}

///|
pub(all) struct SustainedBalanceHead {
  ankle : LearnedAnkleHead
  waist_index : Int32
  waist_lower : Double
  waist_upper : Double
  control_waist : Bool
  output_bound : Double
  fit_bound : Double
  waist_mean : Array[Double]
  waist_scale : Array[Double]
  waist_weight : Array[Double]
} derive(Debug, ToJson, FromJson)

///|
pub fn SustainedBalanceHead::new(
  names : Array[String],
  lower : Array[Double],
  upper : Array[Double],
  pose_rate~ : Bool = true,
  control_waist~ : Bool = true,
  output_bound~ : Double = 0.45,
  fit_bound~ : Double = 0.45,
) -> SustainedBalanceHead {
  let mut waist_index = -1
  for i, name in names {
    if name == "waist_pitch_joint" {
      waist_index = i
    }
  }
  guard waist_index >= 0 else { abort("missing waist pitch joint") }
  {
    ankle: LearnedAnkleHead::new(
      names,
      lower,
      upper,
      bound=fit_bound,
      pose_rate~,
    ),
    waist_index,
    waist_lower: lower[waist_index],
    waist_upper: upper[waist_index],
    control_waist,
    output_bound,
    fit_bound,
    waist_mean: [0.0, 0.0],
    waist_scale: [1.0, 1.0],
    waist_weight: [0.0, 0.0, 0.0],
  }
}

///|
pub fn SustainedBalanceHead::waist_inputs(
  self : SustainedBalanceHead,
  obs : Array[Double],
  inputs : Array[Array[Double]],
  residual : Array[Double],
) -> Array[Double] {
  let a = residual[0] -
    self.ankle.weight[0][2] / self.ankle.scale[0][2] * inputs[0][2]
  let b = residual[2] -
    self.ankle.weight[2][2] / self.ankle.scale[2][2] * inputs[2][2]
  [
    clip((a + b) / 2.0, -self.fit_bound, self.fit_bound),
    obs[self.ankle.nu + self.waist_index],
  ]
}

///|
pub fn SustainedBalanceHead::predict(
  self : SustainedBalanceHead,
  obs : Array[Double],
  goal : Array[Double],
  features : Array[Double],
) -> Array[Double] {
  let inputs = self.ankle.inputs(obs, features)
  let residual = self.ankle.residual(inputs)
  let result = Array::makei(4, fn(j) {
    clip(
      goal[self.ankle.indices[j]] +
      clip(residual[j], -self.output_bound, self.output_bound),
      self.ankle.lower[j],
      self.ankle.upper[j],
    )
  })
  if self.control_waist {
    let waist = self.waist_inputs(obs, inputs, residual)
    let correction = self.waist_weight[2] +
      (waist[0] - self.waist_mean[0]) /
      self.waist_scale[0] *
      self.waist_weight[0] +
      (waist[1] - self.waist_mean[1]) /
      self.waist_scale[1] *
      self.waist_weight[1]
    result.push(
      clip(
        goal[self.waist_index] +
        clip(correction, -self.output_bound, self.output_bound),
        self.waist_lower,
        self.waist_upper,
      ),
    )
  }
  result
}

///|
pub fn SustainedBalanceHead::fit(
  self : SustainedBalanceHead,
  observations : Array[Array[Double]],
  goals : Array[Array[Double]],
  targets : Array[Array[Double]],
  features : Array[Array[Double]],
  margin~ : Double = 2.0e-6,
) -> (Array[FitReport], FitReport) {
  let inputs = Array::makei(observations.length(), fn(i) {
    self.ankle.inputs(observations[i], features[i])
  })
  let reports = self.ankle.fit(inputs, goals, targets, margin~)
  let x = Array::makei(observations.length(), fn(i) {
    self.waist_inputs(
      observations[i],
      inputs[i],
      self.ankle.residual(inputs[i]),
    )
  })
  for k in 0..<2 {
    let mut mean = 0.0
    for row in x {
      mean += row[k] / x.length().to_double()
    }
    let mut variance = 0.0
    for row in x {
      let d = row[k] - mean
      variance += d * d / x.length().to_double()
    }
    self.waist_mean[k] = mean
    self.waist_scale[k] = @math.maximum(variance.sqrt(), 1.0e-6)
  }
  let matrix : Array[Array[Double]] = []
  let target : Array[Double] = []
  for i in 0..<x.length() {
    let y = targets[i][self.waist_index]
    let residual = y - goals[i][self.waist_index]
    if residual.abs() < self.fit_bound - margin &&
      y > self.waist_lower + margin &&
      y < self.waist_upper - margin {
      matrix.push([
        (x[i][0] - self.waist_mean[0]) / self.waist_scale[0],
        (x[i][1] - self.waist_mean[1]) / self.waist_scale[1],
        1.0,
      ])
      target.push(residual)
    }
  }
  let solution = least_squares(matrix, target)
  for i in 0..<3 {
    self.waist_weight[i] = solution[i]
  }
  let raw = [
    solution[0] / self.waist_scale[0],
    solution[1] / self.waist_scale[1],
  ]
  raw.push(
    solution[2] - raw[0] * self.waist_mean[0] - raw[1] * self.waist_mean[1],
  )
  let mut squared = 0.0
  for i in 0..<target.length() {
    let d = dot(matrix[i], solution) - target[i]
    squared += d * d
  }
  (
    reports,
    {
      uncensored_points: target.length(),
      rank: 3,
      rmse: (squared / target.length().to_double()).sqrt(),
      raw_coefficients: raw,
    },
  )
}

///|
pub(all) enum FeedbackHead {
  Learned(LearnedAnkleHead)
  Sustained(SustainedBalanceHead)
} derive(Debug, ToJson, FromJson)

///|
pub struct LearnedBalanceRunner {
  parent : (Array[Double], Array[Double]) -> Array[Double]
  head : FeedbackHead
  history : BalanceHistory
  mut last_feature : Array[Double]?
  mut last_parent : Array[Double]?
}

///|
pub fn LearnedBalanceRunner::new(
  parent : (Array[Double], Array[Double]) -> Array[Double],
  head : FeedbackHead,
  history : BalanceHistory,
) -> LearnedBalanceRunner {
  { parent, head, history, last_feature: None, last_parent: None, }
}

///|
pub fn LearnedBalanceRunner::predict(
  self : LearnedBalanceRunner,
  observation : Array[Double],
  goal : Array[Double],
) -> Array[Double] {
  let action = (self.parent)(observation, goal).copy()
  let features = self.history.observe(observation)
  self.last_feature = Some(features.copy())
  self.last_parent = Some(action.copy())
  match self.head {
    Learned(head) => {
      let corrected = head.predict(observation, goal, features)
      for j in 0..<4 {
        action[head.indices[j]] = corrected[j]
      }
    }
    Sustained(head) => {
      let corrected = head.predict(observation, goal, features)
      for j in 0..<4 {
        action[head.ankle.indices[j]] = corrected[j]
      }
      if head.control_waist {
        action[head.waist_index] = corrected[4]
      }
    }
  }
  action
}
