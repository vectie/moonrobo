///|
pub struct RunningNorm {
  mean : Array[Double]
  variance : Array[Double]
  mut count : Double
  max_count : Double
  eps : Double
}

///|
pub fn RunningNorm::new(
  dim : Int32,
  max_count~ : Double = 2.0e8,
  eps~ : Double = 0.01,
) -> RunningNorm {
  {
    mean: Array::make(dim, 0.0),
    variance: Array::make(dim, 1.0),
    count: 0.0,
    max_count,
    eps,
  }
}

///|
pub fn RunningNorm::update(
  self : RunningNorm,
  rows : Array[Array[Double]],
) -> Unit {
  if self.count >= self.max_count || rows.is_empty() {
    return
  }
  let n = rows.length().to_double()
  let total = self.count + n
  for j in 0..<self.mean.length() {
    let m = rows.fold(init=0.0, (s, row) => s + row[j]) / n
    let v = rows.fold(init=0.0, (s, row) => s + (row[j] - m) * (row[j] - m)) / n
    let delta = m - self.mean[j]
    self.mean[j] += delta * n / total
    self.variance[j] = (
        self.variance[j] * self.count +
        v * n +
        delta * delta * self.count * n / total
      ) /
      total
  }
  self.count = total
}

///|
pub fn RunningNorm::std(self : RunningNorm) -> Array[Double] {
  self.variance.map(v => (v + self.eps * self.eps).sqrt())
}

///|
pub fn RunningNorm::apply(
  self : RunningNorm,
  row : Array[Double],
) -> Array[Double] {
  Array::makei(row.length(), i => {
    (row[i] - self.mean[i]) / (self.variance[i] + self.eps * self.eps).sqrt()
  })
}

///|
pub fn RunningNorm::snapshot(
  self : RunningNorm,
) -> (Array[Double], Array[Double], Double) {
  (self.mean.copy(), self.variance.copy(), self.count)
}

///|
pub fn RunningNorm::restore(
  self : RunningNorm,
  mean : Array[Double],
  variance : Array[Double],
  count : Double,
) -> Unit raise {
  guard mean.length() == self.mean.length() &&
    variance.length() == mean.length() &&
    finite(count) &&
    count >= 0.0 else {
    fail("invalid running-normalization checkpoint")
  }
  for i in 0..<mean.length() {
    guard finite(mean[i]) && finite(variance[i]) && variance[i] >= 0.0 else {
      fail("invalid running variance")
    }
    self.mean[i] = mean[i]
    self.variance[i] = variance[i]
  }
  self.count = count
}

///|
pub fn world_targets(s : State, next : State) -> Array[Double] {
  let out = mat_vec(transpose(yaw_mat(s.rotation)), vec_sub(next.p, s.p))
  let rt = transpose(s.rotation)
  out.append(so3_log(mat_mul(rt, next.rotation)))
  out.append(mat_vec(rt, vec_sub(next.v, s.v)))
  out.append(mat_vec(rt, vec_sub(next.w, s.w)))
  out.append(vec_sub(next.q, s.q))
  out.append(vec_sub(next.qd, s.qd))
  out
}

///|
pub fn world_integrate(s : State, delta : Array[Double]) -> State {
  {
    p: vec_add(s.p, mat_vec(yaw_mat(s.rotation), delta[0:3].to_owned())),
    rotation: mat_mul(s.rotation, so3_exp(delta[3:6].to_owned())),
    v: vec_add(s.v, mat_vec(s.rotation, delta[6:9].to_owned())),
    w: vec_add(s.w, mat_vec(s.rotation, delta[9:12].to_owned())),
    q: vec_add(s.q, delta[12:41].to_owned()),
    qd: vec_add(s.qd, delta[41:70].to_owned()),
  }
}

///|
pub fn world_inputs(
  s : State,
  action : Array[Double],
  xi_n : Array[Double],
) -> Array[Double] {
  let out = invariant_features(s)
  out.append(action)
  out.append(xi_n)
  out
}

///|
pub fn lambda_returns(
  rewards : Array[Array[Double]],
  values : Array[Array[Double]],
  terminated : Array[Array[Double]],
  truncated? : Array[Array[Bool]],
  gamma~ : Double = 0.99,
  lam~ : Double = 0.95,
) -> Array[Array[Double]] raise {
  let horizon = rewards.length()
  guard horizon > 0 &&
    values.length() == horizon + 1 &&
    terminated.length() == horizon else {
    fail("invalid GAE trajectory shapes")
  }
  let batch = rewards[0].length()
  for row in rewards {
    guard row.length() == batch else { fail("invalid reward shape") }
  }
  for row in values {
    guard row.length() == batch else { fail("invalid value shape") }
  }
  for row in terminated {
    guard row.length() == batch else { fail("invalid termination shape") }
  }
  if truncated is Some(rows) {
    guard rows.length() == horizon else { fail("invalid truncation shape") }
    for row in rows {
      guard row.length() == batch else { fail("invalid truncation batch") }
    }
  }
  let result = Array::makei(horizon, _ => Array::make(batch, 0.0))
  let mut carry = values[horizon].copy()
  for step in 0..<horizon {
    let t = horizon - 1 - step
    carry = Array::makei(batch, b => {
      let cut = match truncated {
        Some(rows) => rows[t][b]
        None => false
      }
      let trace = if cut { values[t + 1][b] } else { carry[b] }
      rewards[t][b] +
      gamma *
      (1.0 - terminated[t][b]) *
      ((1.0 - lam) * values[t + 1][b] + lam * trace)
    })
    result[t] = carry
  }
  result
}
