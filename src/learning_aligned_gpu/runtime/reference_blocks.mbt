///|
const ReferenceBlockSamples : Int32 = 256

///|
struct ReferenceBlock {
  states : Map[Int32, @aligned.State]
  read : (Int32) -> @aligned.State
}

///|
fn ReferenceBlock::at(
  self : ReferenceBlock,
  frame : Int32,
) -> @aligned.State raise {
  match self.states.get(frame) {
    Some(state) => state
    None => (self.read)(frame)
  }
}

///|
fn ReferenceBlock::goal(
  self : ReferenceBlock,
  motion : @aligned.MotionLibrary,
  frame : Int32,
  count : Int32,
) -> Array[Double] raise {
  let current = self.at(frame)
  let futures = motion.future_frames(frame, count).map(f => self.at(f))
  @aligned.goal_from_states(current, futures, atlas=motion.orthonormal_heading)
}

///|
/// Only one sample block's immutable reference states is retained on the host.
/// Sorting affects IO order only. Consumers use original frame/sample indices,
/// including duplicates and clip-tail padding; no RNG call occurs here.
fn reference_block_frames(
  motion : @aligned.MotionLibrary,
  starts : ArrayView[@aligned.ReplayStart],
  config : @aligned.LearnerConfig,
  limits : BatchLimits,
  history_only~ : Bool = false,
) -> Array[Int32]? raise {
  guard !starts.is_empty() && starts.length() <= ReferenceBlockSamples else {
    fail("reference staging block must contain 1..256 starts")
  }
  let maximum = limits.max_reference_frames.min(motion.states.materialize_limit)
  guard maximum > 0 else {
    fail("positive reference working-set limit required")
  }
  let indices : Map[Int32, Bool] = {}
  let overflow = [false]
  fn add(frame : Int32) -> Unit raise {
    guard frame >= 0 && frame < motion.states.length() else {
      fail("invalid policy reference frame")
    }
    if !overflow[0] && !indices.contains(frame) {
      if indices.length() < maximum {
        indices[frame] = true
      } else {
        overflow[0] = true
      }
    }
  }
  for start in starts {
    let tr = start.start
    guard tr.s.length() == 71 &&
      tr.a_prev.length() == 29 &&
      tr.xi.length() == 33 &&
      start.history.length() == config.hist &&
      tr.frame >= 0 &&
      tr.frame < motion.states.length() else {
      fail("invalid policy replay start")
    }
    let end = motion.clip_end[motion.clip_id[tr.frame]]
    guard config.horizon <= end - tr.frame else {
      fail("policy start cannot supply complete imagined reference horizon")
    }
    for past in start.history {
      guard past.s.length() == 71 &&
        past.a_prev.length() == 29 &&
        past.xi.length() == 33 else {
        fail("invalid policy history frame")
      }
      add(past.frame)
    }
    // Combine overlapping preview windows: t=0..H and preview=1..K.
    // Compute the clipped range without overflowing a global Int32 frame index.
    let last = (tr.frame.to_int64() +
      config.horizon.to_int64() +
      config.goal_frames.to_int64())
      .min(end.to_int64())
      .to_int()
    if !history_only {
      for frame in tr.frame..<=last {
        add(frame)
      }
    }
  }
  // Original limits cover individual gathers/preview lengths, not their union.
  // Keep previously legal tight limits by retaining the scalar-read path.
  if overflow[0] {
    return None
  }
  let frames : Array[Int32] = []
  for frame, _ in indices {
    frames.push(frame)
  }
  frames.sort()
  Some(frames)
}

///|
fn read_reference_block(
  frames : Array[Int32]?,
  read : (Int32) -> @aligned.State,
) -> ReferenceBlock {
  let states : Map[Int32, @aligned.State] = {}
  if frames is Some(frames) {
    for frame in frames {
      states[frame] = read(frame)
    }
  }
  { states, read, }
}

///|
fn gather_reference_block(
  motion : @aligned.MotionLibrary,
  starts : ArrayView[@aligned.ReplayStart],
  config : @aligned.LearnerConfig,
  limits : BatchLimits,
) -> ReferenceBlock raise {
  read_reference_block(reference_block_frames(motion, starts, config, limits), frame => {
    motion.states[frame]
  })
}

///|
fn finish_tensor_blocks(
  backend : @tensor.Backend,
  parts : Array[@tensor.Tensor],
) -> @tensor.Tensor raise {
  guard !parts.is_empty() else { fail("empty tensor staging block list") }
  let result = if parts.length() == 1 {
    parts[0]
  } else {
    backend.concat(parts)
  }
  parts.clear()
  result
}

///|
struct PolicyInputTensors {
  state : @tensor.Tensor
  previous : @tensor.Tensor
  xi : @tensor.Tensor
  history : @tensor.Tensor
  references : Array[@geometry.State]
  reference_fk : @tensor.Tensor?
  goals : Array[@tensor.Tensor]
}

///|
fn stage_policy_inputs(
  backend : @tensor.Backend,
  starts : Array[@aligned.ReplayStart],
  motion : @aligned.MotionLibrary,
  config : @aligned.LearnerConfig,
  mode : @aligned.ObservationMode,
  rng : @numeric.Rng,
  device : Int32,
  dtype : @tensor.DType,
  default_q : Array[Double],
  limits : BatchLimits,
  resident_references~ : ResidentReferences? = None,
) -> PolicyInputTensors raise {
  stage_policy_input_blocks(
    backend,
    motion,
    config,
    mode,
    rng,
    device,
    dtype,
    default_q,
    limits,
    consume => {
      for begin = 0; begin < starts.length(); {
        let end = begin + (starts.length() - begin).min(ReferenceBlockSamples)
        consume(starts[begin:end])
        continue end
      }
    },
    resident_references~,
  )
}

///|
// The visitor and per-block callback are synchronous. Only uploaded tensors
// enter the outer accumulators; no ReplayStart, Transition, source Array[Double]
// or ReferenceBlock is retained after the callback returns.
fn stage_policy_input_blocks(
  backend : @tensor.Backend,
  motion : @aligned.MotionLibrary,
  config : @aligned.LearnerConfig,
  mode : @aligned.ObservationMode,
  rng : @numeric.Rng,
  device : Int32,
  dtype : @tensor.DType,
  default_q : Array[Double],
  limits : BatchLimits,
  visit : ((ArrayView[@aligned.ReplayStart]) -> Unit raise) -> Unit raise,
  resident_references~ : ResidentReferences? = None,
) -> PolicyInputTensors raise {
  if resident_references is Some(resident) {
    return stage_resident_policy_input_blocks(
      backend, motion, config, mode, rng, device, dtype, default_q, limits, visit,
      resident,
    )
  }
  let state_parts : Array[@tensor.Tensor] = []
  let previous_parts : Array[@tensor.Tensor] = []
  let xi_parts : Array[@tensor.Tensor] = []
  let history_parts : Array[@tensor.Tensor] = []
  let reference_parts : Array[Array[@tensor.Tensor]] = Array::makei(
    config.horizon + 1,
    _ => [],
  )
  let goal_parts : Array[Array[@tensor.Tensor]] = Array::makei(
    config.horizon + 1,
    _ => [],
  )
  visit(block_starts => {
    let count = block_starts.length()
    guard count > 0 && count <= ReferenceBlockSamples else {
      fail("policy input staging block must contain 1..256 starts")
    }
    let references = gather_reference_block(
      motion, block_starts, config, limits,
    )
    let state : Array[Double] = []
    let previous : Array[Double] = []
    let xi : Array[Double] = []
    let history : Array[Double] = []
    for start in block_starts {
      state.append(start.start.s)
      previous.append(start.start.a_prev)
      xi.append(start.start.xi)
      for past in start.history {
        history.append(
          observation_with_noise(
            @aligned.unflatten_state(past.s),
            past.a_prev,
            past.xi,
            references.at(past.frame),
            mode,
            default_q,
            config.observation_noise,
            rng,
          ),
        )
      }
    }
    state_parts.push(upload(backend, state, [count, 71], device, dtype))
    previous_parts.push(upload(backend, previous, [count, 29], device, dtype))
    xi_parts.push(upload(backend, xi, [count, 33], device, dtype))
    history_parts.push(
      upload(backend, history, [count, config.hist, mode.dim()], device, dtype),
    )
    for t in 0..<(config.horizon + 1) {
      let ref_values : Array[Double] = []
      let goals : Array[Double] = []
      for start in block_starts {
        let frame = start.start.frame + t
        ref_values.append(@aligned.flatten_state(references.at(frame)))
        goals.append(references.goal(motion, frame, config.goal_frames))
      }
      reference_parts[t].push(
        upload(backend, ref_values, [count, 71], device, dtype),
      )
      goal_parts[t].push(
        upload(backend, goals, [count, 73 * config.goal_frames], device, dtype),
      )
    }
  })
  {
    state: finish_tensor_blocks(backend, state_parts),
    previous: finish_tensor_blocks(backend, previous_parts),
    xi: finish_tensor_blocks(backend, xi_parts),
    history: finish_tensor_blocks(backend, history_parts),
    references: reference_parts.map(parts => {
      // Preserve the previous full-batch geometry shape and dtype operations.
      @geometry.State::from_flat71(
        backend,
        finish_tensor_blocks(backend, parts),
      )
    }),
    goals: goal_parts.map(parts => finish_tensor_blocks(backend, parts)),
    reference_fk: None,
  }
}
