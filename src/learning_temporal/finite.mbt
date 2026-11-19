///|
/// Concrete temporal model-based return, with H-step differentiable dynamics, predicted observation history, known goal previews, and optional finite-horizon value tail.
pub fn finite_imagination(
  model : @training.Dynamics,
  actor : TemporalPolicy,
  value : TemporalValue,
  tape : @numeric.Tape,
  model_parameters : Array[@numeric.Value],
  actor_parameters : Array[@numeric.Value],
  value_parameters : Array[@numeric.Value],
  point : ValuePoint,
  config : @training.RolloutConfig,
) -> @numeric.Value {
  guard point.goals.length() >= config.horizon + 11 &&
    point.remaining >= config.horizon.to_double() * value.dt &&
    point.history.length() == 10 else {
    abort(
      "finite imagination requires complete command schedule and remaining horizon",
    )
  }
  let goals = point.goals.map(fn(row) { tape.vector(row) })
  let context = tape.vector(point.context)
  let result = temporal_imagination(
    tape,
    tape.vector(point.state),
    point.history.map(fn(row) { tape.vector(row) }),
    goals,
    context,
    config.horizon,
    actor.temporal.future_length,
    config.gamma,
    fn(history, goal, future) {
      let h = Array::makei(actor.temporal.history_length, fn(i) {
        history[history.length() - actor.temporal.history_length + i]
      })
      actor.forward(tape, actor_parameters, h, goal, future)
    },
    fn(state, action, context) {
      model.forward(tape, model_parameters, state, action, context)
    },
    fn(state, action) {
      @training.observation(tape, state, action, actor.base.body)
    },
    fn(state, action, previous, goal) {
      @training.step_reward(
        tape,
        state,
        action,
        previous,
        goal,
        actor.base.body.q_indices,
        config.target_height,
      )
    },
    fn(state, history, horizon) {
      value.forward(
        tape,
        value_parameters,
        state,
        history,
        Array::makei(11, fn(i) { goals[horizon + i] }),
        context,
        tape.scalar(point.remaining - horizon.to_double() * value.dt),
      )
    },
    config.bootstrap,
  )
  result.total
}

///|
pub fn imagination_update(
  model : @training.Dynamics,
  actor : TemporalPolicy,
  value : TemporalValue,
  optimizer : @numeric.Adam,
  points : Array[ValuePoint],
  config : @training.RolloutConfig,
) -> (Double, Double) {
  guard config.horizon > 0 && !points.is_empty() else {
    abort("positive imagination horizon and nonempty batch required")
  }
  let tape = @numeric.Tape::new()
  let parameters = actor.parameters()
  let bound = tape.vector(parameters)
  let model_parameters = model.network.bind(tape)
  let value_parameters = value.net.bind(tape)
  let returns = points.map(fn(point) {
    finite_imagination(
      model, actor, value, tape, model_parameters, bound, value_parameters, point,
      config,
    )
  })
  let objective = tape.mean(returns)
  let loss = tape.scale(objective, -1.0 / config.horizon.to_double())
  guard @numeric.finite(loss.value) else {
    abort("nonfinite temporal imagination loss")
  }
  tape.backward(loss)
  let norm = optimizer.step(parameters, tape, bound)
  actor.restore(parameters)
  (objective.value, norm)
}
