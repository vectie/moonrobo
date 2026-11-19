///|
fn physics_branch(
  runtime : @physics.Runtime,
  s : Snapshot,
  controls : Array[Array[Double]],
  target : Targets,
  geometry : @balance.Kinematics,
  dt : Double,
) -> Branch raise {
  runtime.reset_data()
  runtime.set_friction(s.context[0])
  runtime.set_integration(s.integration)
  let substeps = runtime.control_substeps(dt)
  let nu = controls[0].length()
  let mut previous = last_previous(s.observation, nu)
  let states : Array[Array[Double]] = []
  let observations : Array[Array[Double]] = []
  let actions : Array[Array[Double]] = []
  let next_states : Array[Array[Double]] = []
  let rewards : Array[Double] = []
  let terminated : Array[Bool] = []
  let truncated : Array[Bool] = []
  for i, action in controls {
    let obs = if i == 0 {
      s.observation.copy()
    } else {
      runtime.observation(previous)
    }
    let state = runtime.state()
    let after = runtime.step(action, substeps)
    let reward = @ref.reward_from_geometry(
      geometry,
      after,
      action,
      previous,
      target.positions[i],
      target.quaternions[i],
      target.joints[i],
      dt,
    )
    states.push(state)
    observations.push(obs)
    actions.push(action.copy())
    next_states.push(after)
    rewards.push(reward.reward)
    terminated.push(reward.fallen)
    truncated.push(!reward.fallen && i == controls.length() - 1)
    previous = action.copy()
    if reward.fallen {
      break
    }
  }
  {
    state: states,
    observation: observations,
    actions,
    next_state: next_states,
    rewards,
    terminated,
    truncated,
  }
}

///|
fn first_objective(
  model : @training.Dynamics,
  geometry : @balance.Kinematics,
  s : Snapshot,
  target : Targets,
  horizon : Int32,
  first : Array[Double],
  gamma : Double,
  dt : Double,
) -> (Double, Array[Double]) {
  let tape = @numeric.Tape::new()
  let variable = tape.vector(first)
  let mp = model.network.bind(tape)
  let mut state = tape.vector(s.state)
  let mut previous = tape.vector(last_previous(s.observation, first.length()))
  let context = tape.vector(s.context)
  let mut total = tape.scalar(0)
  let mut discount = 1.0
  let mut alive = true
  for t in 0..<horizon {
    let action = if t == 0 { variable } else { tape.vector(s.actions[t]) }
    state = model.forward(tape, mp, state, action, context)
    let (reward, fallen, _) = @ref.reference_reward_graph(
      geometry,
      tape,
      state,
      action,
      previous,
      target.positions[t],
      target.quaternions[t],
      target.joints[t],
      dt~,
    )
    if alive {
      total = tape.add(total, tape.scale(reward, discount))
    }
    alive = alive && !fallen
    previous = action
    discount *= gamma
  }
  tape.backward(total)
  (total.value, variable.map(v => tape.gradient(v)))
}

///|
struct FeedbackInputs {
  snapshot : Snapshot
  history : Array[Array[Double]]
  features : Array[Double]
  planned : Array[Double]
  clip : Int32
  phase : Int32
}

///|
fn feedback_inputs(
  arrays : Map[String, @artifacts.NumericArray],
  actor : @ref.ReferenceActor,
) -> FeedbackInputs raise {
  let h = tensor(arrays, "history")
  if h.shape != [1, actor.history_length, actor.obs_mean.length()] {
    fail("controller history shape differs")
  }
  {
    snapshot: snapshot(arrays),
    history: Array::makei(actor.history_length, i => {
      Array::makei(actor.obs_mean.length(), j => {
        h.values[i * actor.obs_mean.length() + j]
      })
    }),
    features: vector(arrays, "actual_features"),
    planned: vector(arrays, "reference_features"),
    clip: vector(arrays, "clip")[0].to_int(),
    phase: vector(arrays, "phase")[0].to_int(),
  }
}

///|
fn policy_action(
  actor : @ref.ReferenceActor,
  schedule : @ref.ReferenceSchedule,
  inputs : FeedbackInputs,
  history : Array[Array[Double]],
  features : Array[Double],
  step : Int32,
) -> Array[Double] {
  let command = schedule.command(
    inputs.clip,
    inputs.phase + step,
    actor.future_length,
  )
  let planned = if step == 0 {
    inputs.planned
  } else {
    schedule.features(inputs.clip, 0, inputs.phase + step)
  }
  actor.forward(
    history,
    command.current,
    command.future,
    command.valid,
    features,
    planned,
  )
}

///|
fn feedback_physics(
  runtime : @physics.Runtime,
  actor : @ref.ReferenceActor,
  geometry : @balance.Kinematics,
  schedule : @ref.ReferenceSchedule,
  inputs : FeedbackInputs,
  target : Targets,
  perturbation : Array[Array[Double]],
  dt : Double,
) -> Branch raise {
  let s = inputs.snapshot
  runtime.reset_data()
  runtime.set_friction(s.context[0])
  runtime.set_integration(s.integration)
  let substeps = runtime.control_substeps(dt)
  let mut history = inputs.history.map(h => h.copy())
  let mut features = inputs.features.copy()
  let mut memory = @ref.observer_memory(history[history.length() - 1], features)
  let mut previous = last_previous(history[history.length() - 1], actor.nu)
  let states : Array[Array[Double]] = []
  let observations : Array[Array[Double]] = []
  let actions : Array[Array[Double]] = []
  let next_states : Array[Array[Double]] = []
  let rewards : Array[Double] = []
  let terminated : Array[Bool] = []
  let truncated : Array[Bool] = []
  for t, delta in perturbation {
    let base = policy_action(actor, schedule, inputs, history, features, t)
    let action = runtime.clip_control(
      Array::makei(base.length(), i => base[i] + delta[i]),
    )
    let obs = if t == 0 {
      s.observation.copy()
    } else {
      runtime.observation(previous)
    }
    for i, v in previous {
      obs[obs.length() - actor.nu + i] = v
    }
    let state = runtime.state()
    let after = runtime.step(action, substeps)
    let reward = @ref.reward_from_geometry(
      geometry,
      after,
      action,
      previous,
      target.positions[t],
      target.quaternions[t],
      target.joints[t],
      dt,
    )
    let next_obs = geometry_observation(after, action)
    let (next_features, next_memory) = @ref.observer_advance(
      next_obs,
      memory,
      dt,
      reward.error,
    )
    features = next_features
    memory = next_memory
    history = Array::makei(history.length(), i => {
      if i + 1 < history.length() {
        history[i + 1]
      } else {
        next_obs
      }
    })
    states.push(state)
    observations.push(obs)
    actions.push(action)
    next_states.push(after)
    rewards.push(reward.reward)
    terminated.push(reward.fallen)
    truncated.push(!reward.fallen && t == perturbation.length() - 1)
    previous = action.copy()
    if reward.fallen {
      break
    }
  }
  {
    state: states,
    observation: observations,
    actions,
    next_state: next_states,
    rewards,
    terminated,
    truncated,
  }
}

///|
struct ModelResponse {
  objective : Double
  controls : Array[Array[Double]]
  gradient : Array[Array[Double]]
  active_steps : Int32
}

///|
fn model_response(
  model : @training.Dynamics,
  actor : @ref.ReferenceActor,
  geometry : @balance.Kinematics,
  schedule : @ref.ReferenceSchedule,
  inputs : FeedbackInputs,
  target : Targets,
  perturbation : Array[Array[Double]],
  mode : String,
  lower : Array[Double],
  upper : Array[Double],
  gamma : Double,
  dt : Double,
) -> ModelResponse {
  let tape = @numeric.Tape::new()
  let variable = perturbation.map(p => tape.vector(p))
  let mp = model.network.bind(tape)
  let ap = tape.vector(actor.parameters())
  let mut state = tape.vector(inputs.snapshot.state)
  let context = tape.vector(inputs.snapshot.context)
  let mut history = inputs.history.map(h => tape.vector(h))
  let mut features = tape.vector(inputs.features)
  let mut memory = @ref.observer_memory_graph(
    tape,
    history[history.length() - 1],
    features,
  )
  let mut previous = if mode == "open-tape" {
    tape.vector(last_previous(inputs.snapshot.observation, actor.nu))
  } else {
    let last = history[history.length() - 1]
    Array::makei(actor.nu, i => last[last.length() - actor.nu + i])
  }
  let mut total = tape.scalar(0)
  let mut alive = true
  let mut discount = 1.0
  let mut active_steps = 0
  let controls : Array[Array[Double]] = []
  for t, delta in variable {
    let base = if mode == "open-tape" {
      tape.vector(inputs.snapshot.actions[t])
    } else {
      let command = schedule.command(
        inputs.clip,
        inputs.phase + t,
        actor.future_length,
      )
      let current = tape.vector(command.current)
      let future = command.future.map(f => tape.vector(f))
      let latent = actor.latent_graph(
        tape,
        ap,
        history,
        current,
        future,
        command.valid,
      )
      let planned = if t == 0 {
        inputs.planned
      } else {
        schedule.features(inputs.clip, 0, inputs.phase + t)
      }
      actor.action_graph(
        tape,
        latent,
        history,
        current,
        features,
        tape.vector(planned),
      )
    }
    let action = Array::makei(base.length(), i => {
      let requested = tape.add(base[i], delta[i])
      let clipped = tape.clamp(requested, lower[i], upper[i])
      let tie = (if requested.value == lower[i] { 0.5 } else { 1.0 }) *
        (if requested.value == upper[i] { 0.5 } else { 1.0 })
      tape.add(
        tape.scalar(clipped.value),
        tape.scale(tape.sub(clipped, tape.scalar(clipped.value)), tie),
      )
    })
    let predicted = model.forward(tape, mp, state, action, context)
    let (reward, fallen, error) = @ref.reference_reward_graph(
      geometry,
      tape,
      predicted,
      action,
      previous,
      target.positions[t],
      target.quaternions[t],
      target.joints[t],
      dt~,
    )
    if alive {
      total = tape.add(total, tape.scale(reward, discount))
      active_steps += 1
      state = predicted
    }
    if mode == "feedback" {
      let obs = @ref.observation_graph(tape, state, action)
      let (next_features, next_memory) = @ref.observer_advance_graph(
        tape, obs, memory, dt, error,
      )
      if alive {
        features = next_features
        memory = next_memory
        history = Array::makei(history.length(), i => {
          if i + 1 < history.length() {
            history[i + 1]
          } else {
            obs
          }
        })
      }
    }
    controls.push(action.map(a => a.value))
    previous = action
    alive = alive && !fallen
    discount *= gamma
  }
  tape.backward(total)
  {
    objective: total.value,
    controls,
    gradient: variable.map(row => row.map(v => tape.gradient(v))),
    active_steps,
  }
}
