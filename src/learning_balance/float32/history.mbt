///|
pub fn observation_transports(
  gravity : Array[Array[Double]],
  omega : Array[Array[Double]],
  dt : Double,
  transport_method : @balance.TransportMethod,
) -> Array[Array[Double]] {
  Array::makei(gravity.length(), fn(i) {
    if i == 0 || transport_method == BodyDifference {
      @balance.identity()
    } else {
      let mut t = rotation_vector(
        Array::makei(3, fn(j) {
          mul(-0.5 * dt, add(omega[i][j], omega[i - 1][j]))
        }),
      )
      if transport_method == GravityGyro {
        let a = gravity[i - 1]
        let b = gravity[i]
        let an = @balance.clip(sqrt(dot(a, a)), round(1.0e-12), 1.0 / 0.0)
        let bn = @balance.clip(sqrt(dot(b, b)), round(1.0e-12), 1.0 / 0.0)
        let predicted = matvec(t, a.map(fn(v) { div(v, an) }))
        let unit = b.map(fn(v) { div(v, bn) })
        let k = skew([
          sub(mul(predicted[1], unit[2]), mul(predicted[2], unit[1])),
          sub(mul(predicted[2], unit[0]), mul(predicted[0], unit[2])),
          sub(mul(predicted[0], unit[1]), mul(predicted[1], unit[0])),
        ])
        let kk = matmul(k, k)
        let denominator = @balance.clip(
          add(1.0, dot(predicted, unit)),
          round(1.0e-8),
          1.0 / 0.0,
        )
        let id = @balance.identity()
        t = matmul(
          Array::makei(9, fn(j) {
            add(add(id[j], k[j]), div(kk[j], denominator))
          }),
          t,
        )
      }
      t
    }
  })
}

///|
pub fn causal_velocity(
  error : Array[Array[Double]],
  transport : Array[Array[Double]],
  dt : Double,
  window : Int32?,
) -> Array[Array[Double]] {
  let difference = Array::makei(error.length(), fn(i) {
    if i == 0 {
      [0.0, 0.0, 0.0]
    } else {
      let old = matvec(transport[i], error[i - 1])
      Array::makei(3, fn(j) { div(sub(error[i][j], old[j]), dt) })
    }
  })
  let result : Array[Array[Double]] = []
  for i in 0..<error.length() {
    let row = [0.0, 0.0, 0.0]
    match window {
      None =>
        if i > 0 {
          let previous = matvec(transport[i], result[i - 1])
          for j in 0..<3 {
            row[j] = add(mul(0.8, previous[j]), mul(0.2, difference[i][j]))
          }
        }
      Some(n) => {
        let mut product = @balance.identity()
        for lag in 0..<(n - 1) {
          let index = if i - lag < 0 { 0 } else { i - lag }
          if i > lag {
            let contribution = matvec(product, difference[index])
            let weight = 0.2 * @math.pow(0.8, lag.to_double())
            for j in 0..<3 {
              row[j] = add(row[j], mul(weight, contribution[j]))
            }
          }
          product = matmul(product, transport[index])
        }
      }
    }
    result.push(row)
  }
  result
}

///|
pub fn sequence_features(
  geometry : @balance.Kinematics,
  observations : Array[Array[Double]],
  dt : Double,
  window : Int32?,
  transport_method : @balance.TransportMethod,
) -> Array[Array[Double]] {
  let errors = observations.map(fn(row) { from_observation(geometry, row) })
  let gravity = observations.map(fn(row) {
    Array::makei(3, fn(j) { round(row[2 * geometry.nu + j]) })
  })
  let omega = observations.map(fn(row) {
    Array::makei(3, fn(j) { round(row[2 * geometry.nu + 3 + j]) })
  })
  let velocity = causal_velocity(
    errors,
    observation_transports(gravity, omega, dt, transport_method),
    dt,
    window,
  )
  Array::makei(errors.length(), fn(i) {
    let row = errors[i].copy()
    row.append(velocity[i])
    row
  })
}

///|
pub struct History {
  geometry : @balance.Kinematics
  dt : Double
  window : Int32?
  observations : Array[Array[Double]]
  mut velocity : Array[Double]?
}

///|
pub fn History::new(
  geometry : @balance.Kinematics,
  dt : Double,
  window : Int32?,
) -> History {
  guard dt > 0.0 &&
    (match window {
      Some(n) => n > 0
      None => true
    }) else {
    abort("invalid float32 observer cadence/window")
  }
  { geometry, dt, window, observations: [], velocity: None, }
}

///|
pub fn History::observe(
  self : History,
  observation : Array[Double],
) -> Array[Double] {
  self.observations.push(observation.map(round))
  let cap = self.window.unwrap_or(2)
  while self.observations.length() > cap {
    self.observations.remove(0) |> ignore
  }
  match self.window {
    Some(n) => {
      let features = sequence_features(
        self.geometry,
        self.observations,
        self.dt,
        Some(n),
        GravityGyro,
      )
      features[features.length() - 1]
    }
    None => {
      let n = self.observations.length()
      let error = from_observation(self.geometry, self.observations[n - 1])
      let velocity = match self.velocity {
        None => [0.0, 0.0, 0.0]
        Some(previous) => {
          let gravity = self.observations.map(fn(obs) {
            Array::makei(3, fn(j) { obs[2 * self.geometry.nu + j] })
          })
          let omega = self.observations.map(fn(obs) {
            Array::makei(3, fn(j) { obs[2 * self.geometry.nu + 3 + j] })
          })
          let t = observation_transports(gravity, omega, self.dt, GravityGyro)[n -
            1]
          let old_velocity = matvec(t, previous)
          let old_error = matvec(
            t,
            from_observation(self.geometry, self.observations[n - 2]),
          )
          Array::makei(3, fn(j) {
            add(
              mul(0.8, old_velocity[j]),
              div(mul(0.2, sub(error[j], old_error[j])), self.dt),
            )
          })
        }
      }
      self.velocity = Some(velocity)
      error.append(velocity)
      error
    }
  }
}
