///|
/// Additional memory, with no discount to the existing runtime envelope.
/// Device construction keeps chunk tensors until concat completes (at most
/// twice the final payload). Host construction decodes only 256 rows at once.
/// The host reserve includes 32 bytes per staged value for array capacity and
/// conversion copies, plus 64 KiB per live source/preview state. Allocator and
/// CUDA context reservations remain the responsibility of runtime admission.
pub(all) struct ResidentReferenceUsage {
  frames : Int32
  goal_frames : Int32
  resident_bytes : Int64
  device_build_peak_bytes : Int64
  host_build_reserve_bytes : Int64
  build_block_rows : Int32
} derive(Debug, ToJson)

///|
pub fn resident_reference_usage(
  frames : Int32,
  goal_frames : Int32,
  dtype~ : @tensor.DType = Float32,
  max_bytes~ : Int64 = 1073741824L,
) -> ResidentReferenceUsage raise {
  let element_bytes = match dtype {
    Float64 => 8L
    Float32 => 4L
    BFloat16 => 2L
    _ => fail("resident references require a floating point dtype")
  }
  guard frames > 0 && goal_frames > 0 && goal_frames <= 1048576 else {
    fail("invalid resident reference frame/preview count")
  }
  let width = 71L + 73L * goal_frames.to_int64()
  let resident_bytes = bounded_product(
    [frames.to_int64(), width, element_bytes],
    max_bytes,
  )
  guard resident_bytes <= 4611686018427387903L else {
    fail("resident reference build peak overflow")
  }
  let block = frames.min(ReferenceBlockSamples)
  {
    frames,
    goal_frames,
    resident_bytes,
    device_build_peak_bytes: 2L * resident_bytes,
    host_build_reserve_bytes: 32L * block.to_int64() * width +
    65536L * (block.to_int64() + goal_frames.to_int64() + 1L),
    build_block_rows: block,
  }
}

///|
/// Immutable, runner-local cache. Source motion must remain unchanged for the
/// runner's lifetime, just as its checkpoint/catalog hashes require. It has no
/// RNG, replay state, normalization state, autograd graph or checkpoint payload.
/// It must be rebuilt after loading a different reference catalog.
pub struct ResidentReferences {
  backend : @tensor.Backend
  source : @aligned.MotionLibrary
  flat71 : @tensor.Tensor
  goals : @tensor.Tensor
  reference_fk : @tensor.Tensor?
  usage : ResidentReferenceUsage
  cuda_device : Int32
  dtype : @tensor.DType
  names : Array[String]
  hashes : Array[String]
  clip_start : Array[Int32]
  clip_end : Array[Int32]
  source_fps : Double
  limits : BatchLimits
}

///|
pub fn ResidentReferences::usage(
  self : ResidentReferences,
) -> ResidentReferenceUsage {
  self.usage
}

///|
pub fn ResidentReferences::new(
  backend : @tensor.Backend,
  motion : @aligned.MotionLibrary,
  goal_frames : Int32,
  cuda_device~ : Int32 = -1,
  dtype~ : @tensor.DType = Float32,
  max_bytes~ : Int64 = 1073741824L,
  limits~ : BatchLimits = BatchLimits::default(),
  reference_context~ : @geometry.Context? = None,
) -> ResidentReferences raise {
  let usage = resident_reference_usage(
    motion.states.length(),
    goal_frames,
    dtype~,
    max_bytes~,
  )
  guard goal_frames <= motion.states.materialize_limit &&
    !motion.names.is_empty() &&
    motion.names.length() == motion.source_sha256.length() &&
    motion.clip_start.length() == motion.names.length() &&
    motion.clip_end.length() == motion.names.length() else {
    fail("invalid resident reference catalog or preview limit")
  }
  check_limits(
    limits,
    goal_frames.to_int64(),
    usage.build_block_rows.to_int64() * (71L + 73L * goal_frames.to_int64()),
  )
  @tensor.profile_span("batch.resident_reference.build", () => {
    let state_parts : Array[@tensor.Tensor] = []
    let goal_parts : Array[@tensor.Tensor] = []
    for begin = 0; begin < usage.frames; {
      let count = (usage.frames - begin).min(ReferenceBlockSamples)
      let states : Array[Double] = []
      let goals : Array[Double] = []
      for frame in begin..<(begin + count) {
        states.append(@aligned.flatten_state(motion.states[frame]))
        // Preserve all Float64 scalar operations and clip-tail padding from
        // the original route; dtype conversion happens only at upload.
        goals.append(motion.goal(frame, goal_frames))
      }
      state_parts.push(upload(backend, states, [count, 71], cuda_device, dtype))
      goal_parts.push(
        upload(backend, goals, [count, 73 * goal_frames], cuda_device, dtype),
      )
      continue begin + count
    }
    let flat71 = finish_tensor_blocks(backend, state_parts)
    let goals = finish_tensor_blocks(backend, goal_parts)
    let reference_fk = match reference_context {
      None => None
      Some(context) => {
        // Hard cap512MiB, independently admitted with construction/gather
        // workspace by the CLI. Build on the same GPU/dtype from the exact
        // cached flat71 representation used by normal reference staging.
        let width = context.reference_body_width()
        ignore(
          bounded_product(
            [usage.frames.to_int64(), width.to_int64(), 4L],
            536870912L,
          ),
        )
        guard dtype == Float32 && width > 0 && width <= 1152 else {
          fail("reference FK cache requires FP32 and at most64 bodies")
        }
        let parts : Array[@tensor.Tensor] = []
        for begin = 0; begin < usage.frames; {
          let count = (usage.frames - begin).min(512)
          parts.push(
            context.pack_reference_bodies(
              @geometry.State::from_flat71(
                backend,
                flat71.narrow(0, begin, count),
              ),
            ),
          )
          continue begin + count
        }
        Some(finish_tensor_blocks(backend, parts))
      }
    }
    if cuda_device >= 0 {
      // A single scalar readback completes the queued construction on this
      // stream. It occurs once at startup, never in training iterations, so
      // the separate construction timing includes the completed GPU copies.
      ignore(goals.narrow(0, usage.frames - 1, 1).narrow(1, 0, 1).values())
    }
    {
      backend,
      source: motion,
      flat71,
      goals,
      reference_fk,
      usage,
      cuda_device,
      dtype,
      names: motion.names.copy(),
      hashes: motion.source_sha256.copy(),
      clip_start: motion.clip_start.copy(),
      clip_end: motion.clip_end.copy(),
      source_fps: motion.source_fps,
      limits,
    }
  })
}

///|
fn ResidentReferences::check(
  self : ResidentReferences,
  motion : @aligned.MotionLibrary,
  goal_frames : Int32,
  device : Int32,
  dtype : @tensor.DType,
) -> Unit raise {
  guard physical_equal(self.source.states, motion.states) &&
    self.usage.frames == motion.states.length() &&
    self.usage.goal_frames == goal_frames &&
    self.cuda_device == device &&
    self.dtype == dtype &&
    self.names == motion.names &&
    self.hashes == motion.source_sha256 &&
    self.clip_start == motion.clip_start &&
    self.clip_end == motion.clip_end &&
    self.source_fps == motion.source_fps else {
    fail("resident reference catalog, preview, dtype or device differs")
  }
}

///|
/// Collection can reuse exactly the same table as actor staging. This lookup
/// uploads only frame indices and returns a detached tensor of cached goals.
pub fn ResidentReferences::goals_for_frames(
  self : ResidentReferences,
  frames : Array[Int32],
) -> @tensor.Tensor raise {
  guard !frames.is_empty() &&
    frames.all(frame => frame >= 0 && frame < self.usage.frames) else {
    fail("resident reference lookup frame is out of bounds")
  }
  check_limits(
    self.limits,
    frames.length().to_int64() * self.usage.goal_frames.to_int64(),
    frames.length().to_int64() * 73L * self.usage.goal_frames.to_int64(),
  )
  self.goals.index_select(
    upload(
      self.backend,
      frames.map(f => f.to_double()),
      [frames.length()],
      self.cuda_device,
      Int64,
    ),
  )
}

///|
fn stage_resident_policy_input_blocks(
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
  resident : ResidentReferences,
) -> PolicyInputTensors raise {
  // Validate before the visitor consumes any sample/noise RNG.
  resident.check(motion, config.goal_frames, device, dtype)
  let state_parts : Array[@tensor.Tensor] = []
  let previous_parts : Array[@tensor.Tensor] = []
  let xi_parts : Array[@tensor.Tensor] = []
  let history_parts : Array[@tensor.Tensor] = []
  let frames : Array[Int32] = []
  visit(starts => {
    let references = read_reference_block(
      reference_block_frames(motion, starts, config, limits, history_only=true),
      frame => motion.states[frame],
    )
    let state : Array[Double] = []
    let previous : Array[Double] = []
    let xi : Array[Double] = []
    let history : Array[Double] = []
    for start in starts {
      frames.push(start.start.frame)
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
    let count = starts.length()
    state_parts.push(upload(backend, state, [count, 71], device, dtype))
    previous_parts.push(upload(backend, previous, [count, 29], device, dtype))
    xi_parts.push(upload(backend, xi, [count, 33], device, dtype))
    history_parts.push(
      upload(backend, history, [count, config.hist, mode.dim()], device, dtype),
    )
  })
  let batch = frames.length()
  // This small Int64 index table is time-major, preserving the old sample
  // order exactly. One upload replaces all reference/goal payload uploads.
  let gathered = @tensor.profile_span("batch.resident_reference.gather", () => {
    let indices = upload(
      backend,
      Array::makei((config.horizon + 1) * batch, i => {
        (frames[i % batch] + i / batch).to_double()
      }),
      [config.horizon + 1, batch],
      device,
      Int64,
    )
    let references : Array[@geometry.State] = []
    let goals : Array[@tensor.Tensor] = []
    for t in 0..<(config.horizon + 1) {
      let index = indices.narrow(0, t, 1).reshape([batch])
      references.push(
        @geometry.State::from_flat71(
          backend,
          resident.flat71.index_select(index),
        ),
      )
      goals.push(resident.goals.index_select(index))
    }
    let fk = resident.reference_fk.map(table => {
      table
      .index_select(indices.reshape([-1]))
      .reshape([config.horizon + 1, batch, table.shape()[1]])
    })
    (references, goals, fk)
  })
  {
    state: finish_tensor_blocks(backend, state_parts),
    previous: finish_tensor_blocks(backend, previous_parts),
    xi: finish_tensor_blocks(backend, xi_parts),
    history: finish_tensor_blocks(backend, history_parts),
    references: gathered.0,
    goals: gathered.1,
    reference_fk: gathered.2,
  }
}
