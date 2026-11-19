///|
struct TemporalOrigin {
  physical : @tphysics.Origin
  history : Array[Array[Double]]
  raw : Json
  reference : Array[Json]
}

///|
fn temporal_origin(
  runtime : @physics.Runtime,
  raw : Json,
  actor : @temporal.TemporalPolicy,
  config : Json,
) -> TemporalOrigin raise {
  let remaining = int(raw, "remaining_steps")
  let full_history : Array[Array[Double]] = @json.from_json(
    field(raw, "history"),
  )
  if full_history.length() < actor.temporal.history_length {
    fail("insufficient causal history")
  }
  let history = Array::makei(actor.temporal.history_length, i => {
    full_history[full_history.length() - actor.temporal.history_length + i]
  })
  let declared : Array[Array[Double]]? = @json.from_json(
    optional(raw, "goals", Json::null()),
  )
  let goals : Array[Array[Double]] = match declared {
    Some(goals) => goals
    None => {
      let nominal = nums(raw, "nominal")
      let case = field(raw, "case")
      let schedule : @physics.JointSines? = @json.from_json(
        optional(raw, "reference_schedule", Json::null()),
      )
      let offset : Array[Double]? = @json.from_json(
        optional(raw, "reference_offset_rad", Json::null()),
      )
      let dt = num(config, "dt_s")
      let start = int(raw, "start_step")
      let values : Array[Array[Double]] = []
      for t in 0..<(remaining + actor.temporal.future_length + 11) {
        values.push(
          runtime.reference(
            nominal,
            str(case, "motion"),
            (start + t).to_double() * dt,
            schedule?,
            offset?,
          ),
        )
      }
      values
    }
  }
  {
    physical: {
      integration: nums(raw, "integration"),
      state: nums(raw, "state"),
      history,
      goals,
      context: nums(raw, "context"),
      remaining_steps: remaining,
    },
    history: full_history,
    raw,
    reference: @json.from_json(optional(raw, "reference", [].to_json())),
  }
}

///|
fn temporal_point(
  o : TemporalOrigin,
  config : Json,
) -> @temporal.ValuePoint raise {
  {
    state: o.physical.state,
    history: o.history,
    goals: o.physical.goals,
    context: o.physical.context,
    remaining: o.physical.remaining_steps.to_double() * num(config, "dt_s"),
    target: 0,
  }
}

///|
fn temporal_candidate(
  actor : @temporal.TemporalPolicy,
  delta : Array[Double],
  scale : Double,
) -> @temporal.TemporalPolicy raise {
  let result = @temporal.temporal_from_checkpoint(actor.checkpoint({}))
  result.restore(@probes.scaled_actor(actor.parameters(), delta, scale))
  result
}

///|
fn temporal_objective(
  model : @training.Dynamics,
  actor : @temporal.TemporalPolicy,
  value : @temporal.TemporalValue?,
  points : Array[@temporal.ValuePoint],
  parameters : Array[Double],
  config : Json,
  bootstrap : Bool,
) -> (Array[Double], Array[Double]) raise {
  if points.is_empty() {
    fail("empty temporal minibatch")
  }
  let tape = @numeric.Tape::new()
  let ap = tape.vector(parameters)
  let mp = model.network.bind(tape)
  let horizon = int(config, "horizon")
  let gamma = num(config, "gamma")
  let height = num(config, "target_height_m")
  let vp = value.map(v => v.net.bind(tape))
  let values : Array[@numeric.Value] = []
  for point in points {
    let result = match value {
      Some(value) =>
        @temporal.finite_imagination(
          model,
          actor,
          value,
          tape,
          mp,
          ap,
          vp.unwrap(),
          point,
          { horizon, gamma, target_height: height, bootstrap, },
        )
      None => {
        let goals = point.goals.map(g => tape.vector(g))
        let context = tape.vector(point.context)
        @temporal.temporal_imagination(
          tape,
          tape.vector(point.state),
          point.history.map(h => tape.vector(h)),
          goals,
          context,
          horizon,
          actor.temporal.future_length,
          gamma,
          (history, goal, future) => {
            let h = Array::makei(actor.temporal.history_length, i => {
              history[history.length() - actor.temporal.history_length + i]
            })
            actor.forward(tape, ap, h, goal, future)
          },
          (state, action, c) => model.forward(tape, mp, state, action, c),
          (state, previous) => {
            @training.observation(tape, state, previous, actor.base.body)
          },
          (state, action, previous, goal) => {
            @training.step_reward(
              tape,
              state,
              action,
              previous,
              goal,
              actor.base.body.q_indices,
              height,
            )
          },
          (_, _, _) => tape.scalar(0),
          false,
        ).total
      }
    }
    values.push(result)
  }
  tape.backward(tape.mean(values))
  (values.map(v => v.value), ap.map(v => tape.gradient(v)))
}

///|
fn temporal_direction(
  model : @training.Dynamics,
  actor : @temporal.TemporalPolicy,
  value : @temporal.TemporalValue?,
  points : Array[@temporal.ValuePoint],
  config : Json,
  bootstrap : Bool,
) -> @probes.AdamDirection raise {
  let (before, gradient) = temporal_objective(
    model,
    actor,
    value,
    points,
    actor.parameters(),
    config,
    bootstrap,
  )
  @probes.adam_direction(
    actor.parameters(),
    _ => (average(before).unwrap(), gradient),
    num(config, "actor_learning_rate"),
    int(config, "horizon"),
  )
}

///|
fn temporal_physical(
  runtime : @physics.Runtime,
  o : TemporalOrigin,
  actor : @temporal.TemporalPolicy,
  config : Json,
) -> (Json, Array[Array[Double]], Array[Array[Double]]) raise {
  runtime.set_friction(o.physical.context[0])
  let outcome = @tphysics.physical_return(
    runtime,
    o.physical,
    actor,
    num(config, "dt_s"),
    num(config, "gamma"),
    num(config, "target_height_m"),
    fall_height=num(config, "fall_height_m"),
    fall_upright=num(config, "fall_upright_z"),
  )
  let horizon = int(config, "horizon")
  let n = if outcome.steps < horizon { outcome.steps } else { horizon }
  let states = Array::makei(n, i => outcome.states[i])
  let actions = Array::makei(n, i => outcome.actions[i])
  let previous_frame = o.physical.history[o.physical.history.length() - 1]
  let nu = actor.base.lower.length()
  let previous = Array::makei(nu, i => {
    previous_frame[previous_frame.length() - nu + i]
  })
  let local = @probes.score(
    states,
    actions,
    previous,
    Array::makei(n, i => o.physical.goals[i]),
    actor.base.body.q_indices,
    num(config, "target_height_m"),
    num(config, "gamma"),
  )
  (
    {
      "local_return": local,
      "full_return": outcome.soft_return,
      "steps": outcome.steps,
      "failed": outcome.failed,
      "local_steps": n,
    },
    states,
    actions,
  )
}

///|
fn open_loop(
  model : @training.Dynamics,
  origins : Array[TemporalOrigin],
  config : Json,
) -> Array[Json] raise {
  let records : Array[Json] = []
  for i, o in origins {
    if o.reference.is_empty() {
      continue
    }
    let mut state = o.physical.state
    for t, step in o.reference {
      state = model.predict(
        state,
        nums(step, "applied_action"),
        o.physical.context,
      )
      if ints(config, "prediction_steps").contains(t + 1) {
        let target = nums(step, "next_state")
        let p = Array::makei(state.length() - 2, i => state[i + 2])
        let q = Array::makei(target.length() - 2, i => target[i + 2])
        let scale = Array::makei(model.state_stats.scale.length() - 2, i => {
          model.state_stats.scale[i + 2]
        })
        records.push({
          "origin": i,
          "steps": t + 1,
          "normalized_mse": @probes.normalized_mse(p, q, scale),
          "root_height_error_m": (state[2] - target[2]).abs(),
        })
      }
    }
  }
  records
}
