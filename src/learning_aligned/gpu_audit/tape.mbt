///|
fn operation(
  id : String,
  kind : String,
  ids~ : Array[Int32] = [],
  states71~ : Array[Array[Double]] = [],
  targets~ : Array[Array[Double]] = [],
  context~ : Array[Array[Double]] = [],
) -> Operation {
  { id, kind, ids, states71, targets, context, ground_mu: 0.3, }
}

///|
fn input_state(world : Int32, changed : Bool) -> Array[Double] {
  let state = Array::make(71, 0.0)
  state[0] = world.to_double() * 0.04 + (if changed { 0.03 } else { 0.0 })
  state[2] = if changed { 0.86 } else { 0.82 }
  let half_yaw = if changed { 0.1 } else { 0.0 }
  state[3] = @math.cos(half_yaw)
  state[6] = @math.sin(half_yaw)
  if changed {
    state[7] = 0.02
    state[8] = -0.01
    state[12] = 0.2
  }
  let defaults = @aligned.default_joint_positions()
  for i in 0..<29 {
    state[13 + i] = defaults[i]
  }
  if changed {
    state[13] += 0.02
    state[42] = 0.01
  }
  state
}

///|
fn default_tape() -> Tape {
  let baseline = Array::make(33, 0.0)
  baseline[0] = 0.6
  let changed = Array::make(33, 0.0)
  changed[0] = 0.9
  changed[30] = 0.01
  changed[31] = -0.02
  changed[32] = 0.015
  let ops = [
    operation("context-baseline", "context", ids=[0, 1], context=[
      baseline.copy(),
      baseline.copy(),
    ]),
    operation("reset-both", "reset", ids=[0, 1], states71=[
      input_state(0, false),
      input_state(1, false),
    ]),
    operation("refresh-initial-1", "refresh"),
    operation("refresh-initial-2", "refresh"),
  ]
  for step in 0..<4 {
    let targets = Array::makei(2, env => {
      let q = @aligned.default_joint_positions()
      q[0] += (if env == 0 { 1.0 } else { -1.0 }) *
        (step + 1).to_double() *
        0.005
      q
    })
    ops.push(operation("step-\{step}", "step", targets~))
  }
  ops.push(
    operation("reset-world0", "reset", ids=[0], states71=[input_state(0, true)]),
  )
  ops.push(operation("reset-empty", "reset"))
  ops.push(operation("context-world1", "context", ids=[1], context=[changed]))
  ops.push(operation("refresh-context-1", "refresh"))
  ops.push(operation("refresh-context-2", "refresh"))
  for step in 4..<8 {
    let targets = Array::makei(2, env => {
      let q = @aligned.default_joint_positions()
      q[0] += (if env == 0 { 1.0 } else { -1.0 }) *
        (8 - step).to_double() *
        0.005
      q
    })
    ops.push(operation("step-\{step}", "step", targets~))
  }
  ops.push(
    operation("reset-world1", "reset", ids=[1], states71=[input_state(1, true)]),
  )
  ops.push(operation("refresh-final-1", "refresh"))
  ops.push(operation("refresh-final-2", "refresh"))
  {
    format: "moonrobo.apic-audit-tape.v1",
    num_envs: 2,
    operations: ops,
    selected_worlds: None,
  }
}

///|
fn selected_tape(
  num_envs : Int32,
  capacity_profile~ : @capacity.CapacityProfile = Initial,
) -> Tape raise {
  validate_selected_count(num_envs, capacity_profile)
  let worlds = [0, num_envs / 2, num_envs - 1]
  let all = Array::makei(num_envs, i => i)
  let baseline = Array::make(33, 0.0)
  baseline[0] = 0.6
  let ops = [
    operation(
      "context-baseline",
      "context",
      ids=all,
      context=all.map(_ => baseline.copy()),
    ),
    operation(
      "reset-all",
      "reset",
      ids=all,
      states71=all.map(world => input_state(world, false)),
    ),
    operation("refresh-initial-1", "refresh"),
    operation("refresh-initial-2", "refresh"),
  ]
  for step in 0..<4 {
    ops.push(
      operation(
        "step-\{step}",
        "step",
        targets=Array::makei(num_envs, world => {
          let q = @aligned.default_joint_positions()
          q[0] += (if world % 2 == 0 { 1.0 } else { -1.0 }) *
            (step + 1).to_double() *
            0.005
          q
        }),
      ),
    )
  }
  for world in worlds {
    let changed = Array::make(33, 0.0)
    changed[0] = 0.9
    changed[30] = 0.01
    changed[31] = -0.02
    changed[32] = 0.015
    ops.push(
      operation("reset-world\{world}", "reset", ids=[world], states71=[
        input_state(world, true),
      ]),
    )
    ops.push(
      operation("context-world\{world}", "context", ids=[world], context=[
        changed,
      ]),
    )
    ops.push(operation("refresh-world\{world}-1", "refresh"))
    ops.push(operation("refresh-world\{world}-2", "refresh"))
  }
  ops.push(operation("reset-empty", "reset"))
  for step in 4..<8 {
    ops.push(
      operation(
        "step-\{step}",
        "step",
        targets=Array::makei(num_envs, world => {
          let q = @aligned.default_joint_positions()
          q[0] += (if world % 2 == 0 { 1.0 } else { -1.0 }) *
            (8 - step).to_double() *
            0.005
          q
        }),
      ),
    )
  }
  ops.push(operation("refresh-final-1", "refresh"))
  ops.push(operation("refresh-final-2", "refresh"))
  {
    format: "moonrobo.apic-audit-tape.v2",
    num_envs,
    operations: ops,
    selected_worlds: Some(worlds),
  }
}
