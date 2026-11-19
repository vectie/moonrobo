///|
fn replay_rows(
  input : Map[String, @artifacts.NumericArray],
) -> Array[Array[@aligned.Transition]] raise {
  let s = rows(input, "replay.s", 71)
  let next = rows(input, "replay.s1", 71)
  let actions = rows(input, "replay.a", 29)
  let previous = rows(input, "replay.a_prev", 29)
  let xi = rows(input, "replay.xi", 33)
  let f = get(input, "replay.f")
  let steps = get(input, "replay.ep_step").values
  let done = get(input, "replay.done").values
  guard f.shape.length() == 2 else {
    fail("replay source must be time x environment")
  }
  let time = f.shape[0]
  let env = f.shape[1]
  Array::makei(time, i => {
    Array::makei(env, j => {
      let k = i * env + j
      transition(
        s[k],
        next[k],
        actions[k],
        previous[k],
        xi[k],
        f.values[k].to_int(),
        steps[k].to_int(),
        done=done[k] != 0.0,
      )
    })
  })
}

///|
fn export_transitions(
  output : Map[String, @artifacts.NumericArray],
  prefix : String,
  transitions : Array[@aligned.Transition],
  shape : Array[Int32],
  full~ : Bool,
) -> Unit {
  let fields = if full { ["s", "s1", "a", "xi"] } else { ["s", "a_prev", "xi"] }
  for name in fields {
    let data = transitions.map(tr => {
      match name {
        "s" => tr.s
        "s1" => tr.s1
        "a" => tr.a
        "a_prev" => tr.a_prev
        _ => tr.xi
      }
    })
    let dims = shape.copy()
    dims.push(
      if name == "s" || name == "s1" {
        71
      } else if name == "xi" {
        33
      } else {
        29
      },
    )
    output[prefix + name] = array(dims, flatten(data))
  }
  if full {
    output[prefix + "done"] = array(
      shape,
      transitions.map(tr => if tr.done() { 1.0 } else { 0.0 }),
      dtype="|b1",
    )
  } else {
    output[prefix + "f"] = array(
      shape,
      transitions.map(tr => tr.frame.to_double()),
      dtype="<i8",
    )
  }
}

///|
pub fn candidate_replay(
  input : Map[String, @artifacts.NumericArray],
) -> Map[String, @artifacts.NumericArray] raise {
  let source = replay_rows(input)
  let capacity = number(input, "config.replay_capacity", default=8.0).to_int()
  let replay = @aligned.ReplayBuffer::new(capacity, source[0].length())
  for row in source {
    replay.add(row)
  }
  let ages = get(input, "inputs.window_ages").values
  let envs = get(input, "inputs.window_environments").values
  let mut cursor = 0
  let window = replay.sample_windows(ages.length(), 8, high => {
    let index = cursor / 2
    let value = if cursor % 2 == 0 { ages[index] } else { envs[index] }
    cursor += 1
    guard value >= 0.0 && value < high.to_double() else {
      abort("bound fixed replay age/environment out of range")
    }
    value.to_int()
  })
  let output : Map[String, @artifacts.NumericArray] = {}
  let transitions = []
  for w in window {
    transitions.append(w.transitions)
  }
  export_transitions(
    output,
    "windows.",
    transitions,
    [window.length(), 8],
    full=true,
  )
  output["windows.mask"] = array(
    [window.length(), 8],
    flatten(window.map(w => w.mask)),
  )
  let starts = get(input, "inputs.start_ages").values
  let mut next = 0
  let selected = replay.sample_starts(starts.length(), 10, high => {
    let age = starts[next].to_int()
    next += 1
    guard age >= 0 && age < high else { abort("fixed start age out of range") }
    age
  })
  export_transitions(
    output,
    "starts.",
    selected.map(s => s.start),
    [selected.length()],
    full=false,
  )
  let history = []
  for s in selected {
    history.append(s.history)
  }
  export_transitions(
    output,
    "history.",
    history,
    [selected.length(), 10],
    full=false,
  )
  let restored = @aligned.ReplayBuffer::new(capacity, source[0].length())
  restored.restore(replay.snapshot())
  assert_eq(restored.snapshot().to_json(), replay.snapshot().to_json())
  let restore_ages = get(input, "inputs.restore_ages").values
  let mut first = 0
  let mut second = 0
  let before = replay.sample_starts(restore_ages.length(), 10, _ => {
    let a = restore_ages[first].to_int()
    first += 1
    a
  })
  let after = restored.sample_starts(restore_ages.length(), 10, _ => {
    let a = restore_ages[second].to_int()
    second += 1
    a
  })
  for i, s in before {
    assert_eq(s.start.to_json(), after[i].start.to_json())
    assert_eq(s.history.to_json(), after[i].history.to_json())
  }
  export_transitions(
    output,
    "restored.starts.",
    after.map(s => s.start),
    [after.length()],
    full=false,
  )
  let histories = []
  for s in after {
    histories.append(s.history)
  }
  export_transitions(
    output,
    "restored.history.",
    histories,
    [after.length(), 10],
    full=false,
  )
  output
}

///|
/// Independent age/ring equations transcribed from pinned smc/buffer.py.
/// This oracle never calls the MoonBit ReplayBuffer implementation.
pub fn replay_mathematical_oracle(
  input : Map[String, @artifacts.NumericArray],
) -> Map[String, @artifacts.NumericArray] raise {
  let source = replay_rows(input)
  let capacity = number(input, "config.replay_capacity", default=8.0).to_int()
  let oldest = (source.length() - capacity).max(0)
  let size = source.length().min(capacity)
  let ages = get(input, "inputs.window_ages").values
  let envs = get(input, "inputs.window_environments").values
  let output : Map[String, @artifacts.NumericArray] = {}
  let windows = []
  let masks = []
  for i, age in ages {
    guard age >= 0.0 && age.to_int() + 8 <= size else {
      fail("independent replay window age out of bounds")
    }
    let mut valid = 1.0
    for j in 0..<8 {
      let tr = source[oldest + age.to_int() + j][envs[i].to_int()]
      windows.push(tr)
      masks.push(valid)
      if tr.done() {
        valid = 0.0
      }
    }
  }
  export_transitions(output, "windows.", windows, [ages.length(), 8], full=true)
  output["windows.mask"] = array([ages.length(), 8], masks)
  for
    (key, prefix) in [
      ("inputs.start_ages", ""),
      ("inputs.restore_ages", "restored."),
    ] {
    let selected = get(input, key).values
    let starts = []
    let histories = []
    for a in selected {
      let age = a.to_int()
      guard age >= 0 && age < size else {
        fail("independent replay start out of bounds")
      }
      let tr = source[oldest + age][0]
      starts.push(tr)
      for j in 0..<10 {
        let back = (9 - j).min(tr.ep_step).min(age)
        histories.push(source[oldest + age - back][0])
      }
    }
    export_transitions(
      output,
      prefix + "starts.",
      starts,
      [starts.length()],
      full=false,
    )
    export_transitions(
      output,
      prefix + "history.",
      histories,
      [starts.length(), 10],
      full=false,
    )
  }
  output
}
