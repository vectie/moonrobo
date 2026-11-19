///|
pub(all) struct ReferenceClip {
  goals : Array[Array[Double]]
  positions : Array[Array[Array[Double]]]
  quaternions : Array[Array[Double]]
} derive(Debug)

///|
pub struct ReferenceSchedule {
  clips : Array[ReferenceClip]
  length : Int32
  dt : Double
  reference_features : Map[(Int32, Int32), Array[Array[Double]]]
}

///|
pub fn ReferenceSchedule::new(
  clips : Array[ReferenceClip],
  geometry : @balance.Kinematics,
  origins : Array[Int32],
  dt : Double,
) -> ReferenceSchedule {
  guard !clips.is_empty() && dt > 0.0 else {
    abort("nonempty references and positive dt required")
  }
  let length = clips[0].goals.length() - 1
  let reference_features : Map[(Int32, Int32), Array[Array[Double]]] = Map([])
  for clip, reference in clips {
    guard reference.goals.length() == length + 1 &&
      reference.positions.length() == length + 1 &&
      reference.quaternions.length() == length + 1 else {
      abort("bounded comparison requires equal clip lengths")
    }
    for origin in origins {
      guard origin >= 0 && origin <= length else {
        abort("reference origin out of bounds")
      }
      let obs = reference.goals[origin:].map(goal => {
        reference_observation(goal, nu=geometry.nu)
      })
      reference_features[(clip, origin)] = @balance.sequence_features(
        geometry,
        obs,
        dt,
        None,
        @balance.GravityGyro,
      )
    }
  }
  { clips, length, dt, reference_features, }
}

///|
pub fn ReferenceSchedule::command(
  self : ReferenceSchedule,
  clip : Int32,
  step : Int32,
  future_length : Int32,
) -> ReferenceCommand {
  reference_command(self.clips[clip].goals, step, future_length)
}

///|
pub fn ReferenceSchedule::features(
  self : ReferenceSchedule,
  clip : Int32,
  origin : Int32,
  step : Int32,
) -> Array[Double] {
  self.reference_features[(clip, origin)][step.min(self.length) - origin].copy()
}

///|
pub struct ReferenceRunner {
  actor : ReferenceActor
  history : ReferenceHistory
  actual : @balance.BalanceHistory
  planned : @balance.BalanceHistory
}

///|
pub fn ReferenceRunner::new(
  actor : ReferenceActor,
  geometry : @balance.Kinematics,
  dt : Double,
) -> ReferenceRunner {
  {
    actor,
    history: ReferenceHistory::new(actor.history_length),
    actual: @balance.BalanceHistory::full_memory(geometry, dt),
    planned: @balance.BalanceHistory::full_memory(geometry, dt),
  }
}

///|
pub fn ReferenceRunner::predict(
  self : ReferenceRunner,
  obs : Array[Double],
  current : Array[Double],
  future : Array[Array[Double]],
  valid : Array[Bool],
) -> Array[Double] {
  self.actor.forward(
    self.history.push(obs),
    current,
    future,
    valid,
    self.actual.observe(obs),
    self.planned.observe(reference_observation(current, nu=self.actor.nu)),
  )
}

///|
pub fn ReferenceArchive::clip(self : ReferenceArchive) -> ReferenceClip raise {
  let state = self.matrix("state")
  guard self.arrays.get("body_position") is Some(positions) &&
    positions.shape.length() == 3 &&
    positions.shape[0] == state.length() &&
    positions.shape[2] == 3 else {
    fail("invalid reference position shape")
  }
  let bodies = positions.shape[1]
  {
    goals: self.goals(),
    quaternions: state.map(row => row[3:7].to_owned()),
    positions: Array::makei(state.length(), i => {
      Array::makei(bodies, body => {
        positions.values[(i * bodies + body) * 3:(i * bodies + body + 1) * 3].to_owned()
      })
    }),
  }
}
