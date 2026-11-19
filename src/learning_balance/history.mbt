///|
pub(all) enum TransportMethod {
  BodyDifference
  Gyro
  GravityGyro
} derive(Debug, Eq)

///|
pub fn observation_transports(
  gravity : Array[Array[Double]],
  omega : Array[Array[Double]],
  dt : Double,
  method : TransportMethod,
) -> Array[Array[Double]] {
  guard gravity.length() == omega.length() && dt > 0.0 else {
    abort("invalid IMU sequence")
  }
  let result : Array[Array[Double]] = []
  for i in 0..<gravity.length() {
    if i == 0 || method == BodyDifference {
      result.push(identity())
      continue
    }
    let mut transport = rotation_vector(
      Array::makei(3, fn(j) { -0.5 * dt * (omega[i][j] + omega[i - 1][j]) }),
    )
    if method == GravityGyro {
      let a = gravity[i - 1]
      let b = gravity[i]
      let an = @math.maximum(dot(a, a).sqrt(), 1.0e-12)
      let bn = @math.maximum(dot(b, b).sqrt(), 1.0e-12)
      let predicted = matvec(transport, a.map(fn(v) { v / an }))
      let unit = b.map(fn(v) { v / bn })
      let cross = skew([
        predicted[1] * unit[2] - predicted[2] * unit[1],
        predicted[2] * unit[0] - predicted[0] * unit[2],
        predicted[0] * unit[1] - predicted[1] * unit[0],
      ])
      let squared = matmul(cross, cross)
      let den = @math.maximum(1.0 + dot(predicted, unit), 1.0e-8)
      let id = identity()
      transport = matmul(
        Array::makei(9, fn(j) { id[j] + cross[j] + squared[j] / den }),
        transport,
      )
    }
    result.push(transport)
  }
  result
}

///|
pub fn causal_velocity(
  errors : Array[Array[Double]],
  transports : Array[Array[Double]],
  dt : Double,
  window : Int32?,
) -> Array[Array[Double]] {
  guard dt > 0.0 && errors.length() == transports.length() else {
    abort("invalid causal sequence")
  }
  let differences = Array::makei(errors.length(), fn(i) {
    if i == 0 {
      [0.0, 0.0, 0.0]
    } else {
      let old = matvec(transports[i], errors[i - 1])
      Array::makei(3, fn(j) { (errors[i][j] - old[j]) / dt })
    }
  })
  let values : Array[Array[Double]] = []
  for i in 0..<errors.length() {
    let v = [0.0, 0.0, 0.0]
    match window {
      None =>
        if i > 0 {
          let previous = matvec(transports[i], values[i - 1])
          for j in 0..<3 {
            v[j] = 0.8 * previous[j] + 0.2 * differences[i][j]
          }
        }
      Some(n) => {
        guard n > 0 else { abort("positive filter window required") }
        let mut product = identity()
        let mut weight = 0.2
        for lag in 0..<(n - 1) {
          if i > lag {
            let term = matvec(product, differences[i - lag])
            for j in 0..<3 {
              v[j] += weight * term[j]
            }
          }
          let index = if i - lag < 0 { 0 } else { i - lag }
          product = matmul(product, transports[index])
          weight *= 0.8
        }
      }
    }
    values.push(v)
  }
  values
}

///|
pub struct BalanceHistory {
  geometry : Kinematics
  dt : Double
  window : Int32?
  method : TransportMethod
  errors : Array[Array[Double]]
  gravity : Array[Array[Double]]
  omega : Array[Array[Double]]
  mut velocity : Array[Double]?
}

///|
pub fn BalanceHistory::new(
  geometry : Kinematics,
  dt : Double,
  window~ : Int32 = 10,
  method~ : TransportMethod = GravityGyro,
) -> BalanceHistory {
  {
    geometry,
    dt,
    window: Some(window),
    method,
    errors: [],
    gravity: [],
    omega: [],
    velocity: None,
  }
}

///|
pub fn BalanceHistory::full_memory(
  geometry : Kinematics,
  dt : Double,
  method~ : TransportMethod = GravityGyro,
) -> BalanceHistory {
  {
    geometry,
    dt,
    window: None,
    method,
    errors: [],
    gravity: [],
    omega: [],
    velocity: None,
  }
}

///|
pub fn BalanceHistory::observe(
  self : BalanceHistory,
  observation : Array[Double],
) -> Array[Double] {
  self.errors.push(self.geometry.from_observation(observation))
  self.gravity.push(
    Array::makei(3, fn(j) { observation[2 * self.geometry.nu + j] }),
  )
  self.omega.push(
    Array::makei(3, fn(j) { observation[2 * self.geometry.nu + 3 + j] }),
  )
  let capacity = self.window.unwrap_or(2)
  if self.errors.length() > capacity {
    self.errors.remove(0) |> ignore
    self.gravity.remove(0) |> ignore
    self.omega.remove(0) |> ignore
  }
  let transports = observation_transports(
    self.gravity,
    self.omega,
    self.dt,
    self.method,
  )
  let n = self.errors.length()
  let v = match self.window {
    Some(_) =>
      causal_velocity(self.errors, transports, self.dt, self.window)[n - 1]
    None =>
      match self.velocity {
        None => [0.0, 0.0, 0.0]
        Some(previous) => {
          let old = matvec(transports[n - 1], previous)
          let e = matvec(transports[n - 1], self.errors[n - 2])
          Array::makei(3, fn(j) {
            0.8 * old[j] + 0.2 * (self.errors[n - 1][j] - e[j]) / self.dt
          })
        }
      }
  }
  self.velocity = Some(v)
  let result = self.errors[n - 1].copy()
  for x in v {
    result.push(x)
  }
  result
}

///|
pub fn sequence_features(
  geometry : Kinematics,
  observations : Array[Array[Double]],
  dt : Double,
  window : Int32?,
  method : TransportMethod,
) -> Array[Array[Double]] {
  let errors = observations.map(fn(row) { geometry.from_observation(row) })
  let gravity = observations.map(fn(row) {
    Array::makei(3, fn(j) { row[2 * geometry.nu + j] })
  })
  let omega = observations.map(fn(row) {
    Array::makei(3, fn(j) { row[2 * geometry.nu + 3 + j] })
  })
  let transports = observation_transports(gravity, omega, dt, method)
  let velocity = causal_velocity(errors, transports, dt, window)
  Array::makei(errors.length(), fn(i) {
    let row = errors[i].copy()
    for v in velocity[i] {
      row.push(v)
    }
    row
  })
}
