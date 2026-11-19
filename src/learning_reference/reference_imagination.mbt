///|
pub(all) struct LearningPoint {
  state : Array[Double]
  history : Array[Array[Double]]
  actual_features : Array[Double]
  reference_features : Array[Double]
  context : Array[Double]
  clip : Int32
  step : Int32
  origin : Int32
} derive(Debug, ToJson, FromJson)

///|
pub(all) enum FeedbackGradient {
  Full
  StopPolicyInputs
} derive(Debug, Eq)

///|
pub fn ReferenceValue::parameters(self : ReferenceValue) -> Array[Double] {
  let parameters : Array[Double] = []
  for layer in self.net {
    for row in layer.weight {
      parameters.append(row)
    }
    parameters.append(layer.bias)
  }
  parameters
}

///|
pub fn ReferenceValue::set_parameters(
  self : ReferenceValue,
  parameters : Array[Double],
) -> Unit {
  let mut i = 0
  for layer in self.net {
    for row in layer.weight {
      for j in 0..<row.length() {
        row[j] = parameters[i]
        i += 1
      }
    }
    for j in 0..<layer.bias.length() {
      layer.bias[j] = parameters[i]
      i += 1
    }
  }
  guard i == parameters.length() else { abort("value parameter count") }
}

///|
pub fn ReferenceValue::forward_graph(
  self : ReferenceValue,
  t : @numeric.Tape,
  parameters : Array[@numeric.Value],
  state : Array[@numeric.Value],
  history : Array[Array[@numeric.Value]],
  current : Array[Double],
  features : Array[@numeric.Value],
  reference_features : Array[Double],
  context : Array[Double],
  clip : Int32,
  step : Int32,
  remaining : Int32,
  root_position : Array[Double],
  root_quaternion : Array[Double],
) -> @numeric.Value {
  let relative = state.mapi((i, x) => {
    if i < 3 {
      t.sub(x, t.scalar(root_position[i]))
    } else {
      x
    }
  })
  let input = normalize_graph(t, relative, self.state_mean, self.state_scale)
  for obs in history {
    input.append(normalize_graph(t, obs, self.obs_mean, self.obs_scale))
  }
  input.append(t.vector(normalize(current, self.goal_mean, self.goal_scale)))
  for x in features[3:] {
    input.push(t.scale(x, 5.0))
  }
  for x in reference_features[3:] {
    input.push(t.scalar(x * 5.0))
  }
  input.append(t.vector(context))
  for i in 0..<self.clips {
    input.push(t.scalar(if i == clip { 1.0 } else { 0.0 }))
  }
  input.push(t.scalar(step.to_double() / 1500.0))
  input.push(t.scalar(remaining.to_double() / 1500.0))
  input.append(t.vector(root_quaternion))
  t.scale(
    t.tanh(
      t.scale(dense_graph(self.net, t, parameters, 0, input).0[0], 1.0 / 6.0),
    ),
    6.0,
  )
}

///|
pub fn fit_reference_value(
  value : ReferenceValue,
  optimizer : @numeric.Adam,
  points : Array[LearningPoint],
  returns : Array[Double],
  schedule : ReferenceSchedule,
) -> Double {
  guard !points.is_empty() && points.length() == returns.length() else {
    abort("value fit shape")
  }
  let t = @numeric.Tape::new()
  let values = value.parameters()
  let parameters = t.vector(values)
  let errors = points.mapi((i, point) => {
    let clip = schedule.clips[point.clip]
    let predicted = value.forward_graph(
      t,
      parameters,
      t.vector(point.state),
      point.history.map(row => t.vector(row)),
      clip.goals[point.step],
      t.vector(point.actual_features),
      point.reference_features,
      point.context,
      point.clip,
      point.step,
      schedule.length - point.step,
      clip.positions[point.step][0],
      clip.quaternions[point.step],
    )
    let error = t.scale(t.sub(predicted, t.scalar(returns[i])), 1.0 / 6.0)
    t.mul(error, error)
  })
  let loss = t.mean(errors)
  guard finite(loss.value) else { abort("nonfinite reference value fit") }
  t.backward(loss)
  ignore(optimizer.step(values, t, parameters))
  value.set_parameters(values)
  loss.value
}

///|
/// Frozen world model/value parameters remain on the tape so their input edges
/// retain BPTT. Only actor parameters are handed to Adam by the caller.
/// The optional initial_graph observer exposes bound initial state/features for
/// gradient diagnostics; omitting it leaves the training graph unchanged.
pub fn imagined_objective(
  t : @numeric.Tape,
  model : @training.Dynamics,
  actor : ReferenceActor,
  actor_parameters : Array[@numeric.Value],
  value : ReferenceValue?,
  batch : Array[LearningPoint],
  geometry : @balance.Kinematics,
  schedule : ReferenceSchedule,
  horizon : Int32,
  gamma : Double,
  feedback_gradient~ : FeedbackGradient = Full,
  critic_tail~ : Bool = true,
  initial_graph? : (Int32, Array[@numeric.Value], Array[@numeric.Value]) -> Unit,
) -> (@numeric.Value, Int32) {
  guard !batch.is_empty() && horizon >= 0 else { abort("imagination shape") }
  let model_parameters = model.network.bind(t)
  let value_parameters = match value {
    Some(v) => t.vector(v.parameters())
    None => []
  }
  let objectives : Array[@numeric.Value] = []
  let mut active_steps = 0
  for index, point in batch {
    let mut state = t.vector(point.state)
    let mut history = point.history.map(row => t.vector(row))
    let mut features = t.vector(point.actual_features)
    if initial_graph is Some(capture) {
      capture(index, state, features)
    }
    let mut memory = observer_memory_graph(
      t,
      history[history.length() - 1],
      features,
    )
    let mut phase = point.step
    let mut planned = point.reference_features
    let mut alive = true
    let mut objective = t.scalar(0.0)
    let mut discount = 1.0
    for _ in 0..<horizon {
      let command = schedule.command(point.clip, phase, actor.future_length)
      let policy_history = if feedback_gradient == StopPolicyInputs {
        history.map(row => t.vector(row.map(x => x.value)))
      } else {
        history
      }
      let policy_features = if feedback_gradient == StopPolicyInputs {
        t.vector(features.map(x => x.value))
      } else {
        features
      }
      let current = t.vector(command.current)
      let latent = actor.latent_graph(
        t,
        actor_parameters,
        policy_history,
        current,
        command.future.map(row => t.vector(row)),
        command.valid,
      )
      let action = actor.action_graph(
        t,
        latent,
        policy_history,
        current,
        policy_features,
        t.vector(planned),
      )
      let predicted = model.forward(
        t,
        model_parameters,
        state,
        action,
        t.vector(point.context),
      )
      let next_phase = (phase + 1).min(schedule.length)
      let reference = schedule.clips[point.clip]
      let last = history[history.length() - 1]
      let previous = last[last.length() - actor.nu:].to_owned()
      let (reward, fallen, error) = reference_reward_graph(
        geometry,
        t,
        predicted,
        action,
        previous,
        reference.positions[next_phase],
        reference.quaternions[next_phase],
        reference.goals[next_phase][:actor.nu].to_owned(),
        dt=schedule.dt,
      )
      if alive {
        objective = t.add(objective, t.scale(reward, discount))
        active_steps += 1
        state = predicted
      }
      let obs = observation_graph(t, state, action)
      let (next_features, next_memory) = observer_advance_graph(
        t,
        obs,
        memory,
        schedule.dt,
        error,
      )
      if alive {
        features = next_features
        memory = next_memory
        history = history[1:].to_owned()
        history.push(obs)
      }
      phase = next_phase
      planned = schedule.features(point.clip, point.origin, phase)
      alive = alive && !fallen && phase < schedule.length
      discount *= gamma
    }
    if critic_tail && alive {
      guard value is Some(value) else {
        abort("critic tail requires a reference value")
      }
      let reference = schedule.clips[point.clip]
      let tail = value.forward_graph(
        t,
        value_parameters,
        state,
        history,
        reference.goals[phase],
        features,
        planned,
        point.context,
        point.clip,
        phase,
        schedule.length - phase,
        reference.positions[phase][0],
        reference.quaternions[phase],
      )
      objective = t.add(objective, t.scale(tail, discount))
    }
    objectives.push(objective)
  }
  (t.mean(objectives), active_steps)
}

///|
pub fn optimize_model_actor_step(
  model : @training.Dynamics,
  actor : ReferenceActor,
  value : ReferenceValue?,
  optimizer : @numeric.Adam,
  batch : Array[LearningPoint],
  geometry : @balance.Kinematics,
  schedule : ReferenceSchedule,
  horizon : Int32,
  gamma : Double,
  feedback_gradient~ : FeedbackGradient = Full,
  critic_tail~ : Bool = true,
) -> (Double, Int32, Double) {
  let t = @numeric.Tape::new()
  let values = actor.parameters()
  let parameters = t.vector(values)
  let (objective, active) = imagined_objective(
    t,
    model,
    actor,
    parameters,
    value,
    batch,
    geometry,
    schedule,
    horizon,
    gamma,
    feedback_gradient~,
    critic_tail~,
  )
  guard finite(objective.value) else {
    abort("nonfinite reference imagined objective")
  }
  t.backward(t.scale(objective, -1.0))
  let norm = optimizer.step(values, t, parameters)
  actor.set_parameters(values)
  (objective.value, active, norm)
}
