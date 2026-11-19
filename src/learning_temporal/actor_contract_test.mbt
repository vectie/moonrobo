///|
/// Additional contracts from test_temporal_actor.py: causality, reload/kind separation and known-goal imagination equivalence with actor gradients.
test "changing a future observation cannot change prior causal histories" {
  let values = [[1.0], [2.0], [3.0], [4.0]]
  let times = [0.0, 0.02, 0.1, 0.12]
  let before = causal_history(values, times, 3, 0.02)
  let changed = [[1.0], [2.0], [3.0], [999.0]]
  let after = causal_history(changed, times, 3, 0.02)
  for i in 0..<3 {
    assert_eq(before[i], after[i])
  }
}

///|
async test "zero adapter and native checkpoint preserve legacy action and reject base loader" {
  let actor = contract_actor(10, 10)
  let rng = @numeric.Rng::new(4U)
  let last = actor.base.network.parameters.length() - 9
  for i in last..<actor.base.network.parameters.length() {
    actor.base.network.parameters[i] = 0.1 * (2.0 * rng.uniform() - 1.0)
  }
  let history = Array::makei(10, fn(_) {
    Array::makei(9, fn(_) { rng.normal() })
  })
  let goal = [0.2]
  let future = Array::makei(10, fn(_) { [rng.normal()] })
  assert_eq(
    actor.predict(history, goal, future),
    actor.base.predict(history[9], goal),
  )
  let folder = @fs.tmpdir(prefix="moonrobo-temporal-actor-")
  defer (@fs.rmdir(folder, recursive=true) catch { _ => () })
  let path = folder + "/temporal-actor-contract.moon.json"
  ignore(save_temporal(path, actor, { "selected_update": 0 }))
  let restored = load_temporal(path)
  assert_eq(
    restored.predict(history, goal, future),
    actor.predict(history, goal, future),
  )
  let encoded = actor.checkpoint(Json::null())
  let base : @training.Actor? = Some(@training.actor_from_checkpoint(encoded)) catch {
    _ => None
  }
  assert_true(base.is_none())
}

///|
test "temporal imagination equals the legacy constant-goal recurrence and has gradients" {
  let actor = contract_actor(1, 0)
  let tape = @numeric.Tape::new()
  let bound = tape.vector(actor.parameters())
  let initial = tape.vector(contract_state())
  let goal = tape.vector([0.2])
  let context = tape.vector([1.0, 1.0])
  let obs = @training.observation(
    tape,
    initial,
    tape.vector([0.0]),
    actor.base.body,
  )
  let dynamics = fn(
    state : Array[@numeric.Value],
    action : Array[@numeric.Value],
    _context : Array[@numeric.Value],
  ) {
    Array::makei(state.length(), fn(i) {
      if i == 7 {
        tape.add(state[i], action[0])
      } else {
        state[i]
      }
    })
  }
  let result = temporal_imagination(
    tape,
    initial,
    [obs],
    [goal, goal, goal, goal, goal],
    context,
    4,
    0,
    0.9,
    fn(h, g, f) { actor.forward(tape, bound, h, g, f) },
    dynamics,
    fn(s, a) { @training.observation(tape, s, a, actor.base.body) },
    fn(s, a, p, g) {
      @training.step_reward(tape, s, a, p, g, actor.base.body.q_indices, 0.8)
    },
    fn(_, _, _) { tape.scalar(0.0) },
    false,
  )
  let mut state = initial
  let mut previous = tape.vector([0.0])
  let mut history = obs
  let mut total = tape.scalar(0.0)
  let mut survival = tape.scalar(1.0)
  let mut discount = 1.0
  for i in 0..<4 {
    let parameters = Array::makei(actor.base.network.parameters.length(), fn(
      j,
    ) {
      bound[j]
    })
    let action = actor.base.forward(tape, parameters, history, goal)
    state = dynamics(state, action, context)
    let (reward, continuation) = @training.step_reward(
      tape,
      state,
      action,
      previous,
      goal,
      actor.base.body.q_indices,
      0.8,
    )
    total = tape.add(total, tape.scale(tape.mul(survival, reward), discount))
    survival = tape.mul(survival, continuation)
    assert_eq(
      result.states[i + 1].map(fn(v) { v.value }),
      state.map(fn(v) { v.value }),
    )
    assert_eq(result.rewards[i].value, reward.value)
    assert_eq(result.continuations[i].value, continuation.value)
    history = @training.observation(tape, state, action, actor.base.body)
    previous = action
    discount *= 0.9
  }
  assert_eq(result.total.value, total.value)
  tape.backward(result.total)
  ignore(check_finite_gradients(tape, bound))
  let changed = [[0.2], [0.1], [-0.1], [-0.2], [0.2]]
  let tape2 = @numeric.Tape::new()
  let b = tape2.vector(actor.parameters())
  let result2 = temporal_imagination(
    tape2,
    tape2.vector(contract_state()),
    [tape2.vector(contract_observation(contract_state(), [0.0]))],
    changed.map(fn(row) { tape2.vector(row) }),
    tape2.vector([1.0, 1.0]),
    4,
    0,
    0.9,
    fn(h, g, f) { actor.forward(tape2, b, h, g, f) },
    fn(s, a, _) {
      Array::makei(s.length(), fn(i) {
        if i == 7 {
          tape2.add(s[i], a[0])
        } else {
          s[i]
        }
      })
    },
    fn(s, a) { @training.observation(tape2, s, a, actor.base.body) },
    fn(s, a, p, g) {
      @training.step_reward(tape2, s, a, p, g, actor.base.body.q_indices, 0.8)
    },
    fn(_, _, _) { tape2.scalar(0.0) },
    false,
  )
  assert_true(result2.total.value != result.total.value)
}
