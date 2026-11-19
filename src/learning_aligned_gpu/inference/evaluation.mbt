///|
/// Full clips at 50 Hz, deterministic actor inputs and unchanged reference-
/// relative physical reward/termination. Only the designated evaluation slot
/// contributes metrics; a fixed GPU batch may still simulate extra replicas.
pub fn Actor::evaluate(
  self : Actor,
  motion : @aligned.MotionLibrary,
  settings : @aligned.EvaluationSettings,
  reset_frame : (Int32) -> Unit raise,
  inspect_frame : () -> @aligned.CollectorFrame raise,
  step_action : (Array[Double]) -> @aligned.Transition raise,
  clip_indices? : Array[Int32],
  default_q~ : Array[Double] = @aligned.default_joint_positions(),
  strict_kin? : @aligned.Kinematics,
  active_axes~ : Int32 = 29,
) -> @aligned.EvaluationSummary raise {
  evaluate_policy(
    self.spec,
    (history, goals) => self.forward(history, goals),
    motion,
    settings,
    reset_frame,
    inspect_frame,
    step_action,
    clip_indices?,
    default_q~,
    strict_kin?,
    active_axes~,
  )
}

///|
/// Backend-independent full-clip protocol. A frozen policy supplies numeric
/// actions; inference runtime selection does not change observations or scoring.
pub fn evaluate_policy(
  spec : ActorSpec,
  forward : (Array[Array[Double]], Array[Double]) -> Array[Double] raise,
  motion : @aligned.MotionLibrary,
  settings : @aligned.EvaluationSettings,
  reset_frame : (Int32) -> Unit raise,
  inspect_frame : () -> @aligned.CollectorFrame raise,
  step_action : (Array[Double]) -> @aligned.Transition raise,
  clip_indices? : Array[Int32],
  default_q~ : Array[Double] = @aligned.default_joint_positions(),
  strict_kin? : @aligned.Kinematics,
  active_axes~ : Int32 = 29,
) -> @aligned.EvaluationSummary raise {
  spec.validate()
  guard settings.eval_mode &&
    !settings.auto_reset &&
    settings.timeout_disabled &&
    !settings.observation_noise &&
    !settings.domain_randomization &&
    settings.simulated_replica_count > 0 else {
    fail(
      "actor evaluation requires full-clip settings without noise, randomization or autoreset",
    )
  }
  let clips = clip_indices.unwrap_or(
    Array::makei(motion.names.length(), i => i),
  )
  guard !clips.is_empty() && clips.length() <= 200000 else {
    fail("evaluation requires 1..200000 clips")
  }
  guard motion.names.length() <= 200000 else {
    fail("evaluation catalog exceeds 200000-clip bound")
  }
  let seen = Array::make(motion.names.length(), false)
  let mut planned_steps = 0L
  for index in clips {
    guard index >= 0 && index < motion.names.length() && !seen[index] else {
      fail("evaluation clips must be distinct valid indices")
    }
    seen[index] = true
    let length = motion.clip_end[index] - motion.clip_start[index]
    guard length > 0 && length <= 1000000 else {
      fail(
        "evaluation requires 1..1000000 transitions per complete clip; it never truncates a clip to fit memory",
      )
    }
    planned_steps += length.to_int64()
  }
  guard planned_steps * settings.simulated_replica_count.to_int64() <=
    2147483647L else {
    fail(
      "evaluation exceeds report counter capacity; select smaller full-clip sets",
    )
  }
  let summaries : Array[@aligned.ClipSummary] = []
  guard active_axes > 0 && active_axes <= 29 else {
    fail("invalid active joint count")
  }
  for index in clips {
    let start = motion.clip_start[index]
    let expected = motion.clip_end[index] - start
    reset_frame(start)
    let mut history : Array[Array[Double]] = []
    let rewards = []
    let squared : Map[String, Double] = {}
    let mut terminated = false
    let mut termination_frame : Int32? = None
    for step in 0..<expected {
      let frame = inspect_frame()
      guard frame.frame == start + step && frame.episode_step == step else {
        fail(
          "evaluation adapter reset or frame progression differs from full clip",
        )
      }
      let obs = @aligned.observation(
        frame.state,
        frame.previous,
        frame.xi,
        default_q,
        motion.states[frame.frame],
        spec.mode(),
      )
      history = if history.is_empty() {
        Array::makei(spec.hist, _ => obs.copy())
      } else {
        let next = history[1:].to_owned()
        next.push(obs)
        next
      }
      let action = forward(history, motion.goal(frame.frame, spec.goal_frames))
      let tr = step_action(action)
      guard tr.frame == frame.frame &&
        tr.ep_step == frame.episode_step &&
        @numeric.finite(tr.r) else {
        fail("evaluation transition does not match inspected frame")
      }
      rewards.push(tr.r)
      if strict_kin is Some(kin) {
        let state = @aligned.unflatten_state(tr.s1)
        let reference = motion.states[tr.frame + 1]
        let joint = Array::makei(active_axes, j => state.q[j] - reference.q[j])
        let root = @aligned.vec_sub(state.p, reference.p)
        let rotation = @aligned.so3_log(
          @aligned.mat_mul(
            @aligned.transpose(state.rotation),
            reference.rotation,
          ),
        )
        let bodies = kin.forward(state)
        let refs = motion.bodies[tr.frame + 1]
        let mut world = 0.0
        let mut relative = 0.0
        for b, body in bodies {
          let difference = @aligned.vec_sub(body.p, refs[b].p)
          world += norm_squared(difference)
          relative += norm_squared(@aligned.vec_sub(difference, root))
        }
        for
          (name, value) in [
            ("joint_rmse_rad", norm_squared(joint) / active_axes.to_double()),
            ("root_position_rmse_m", norm_squared(root)),
            ("root_orientation_rmse_rad", norm_squared(rotation)),
            ("body_position_rmse_m", world / bodies.length().to_double()),
            (
              "root_relative_body_position_rmse_m",
              relative / bodies.length().to_double(),
            ),
          ] {
          squared[name] = squared.get(name).unwrap_or(0.0) + value
        }
      }
      terminated = tr.terminated
      if terminated {
        termination_frame = Some(step + 1)
      }
      if tr.done() {
        break
      }
    }
    let trial : @aligned.ClipEvaluation = {
      clip_id: motion.names[index],
      expected_steps: expected,
      rewards,
      terminated,
      strict_rmse: if strict_kin is Some(_) {
        for name, value in squared {
          squared[name] = (value / rewards.length().to_double()).sqrt()
        }
        Some(squared)
      } else {
        None
      },
      termination_frame,
    }
    // Reduce and release this clip's rewards before reading the next clip.
    // Never retain a corpus-sized per-frame reward list.
    summaries.push(@aligned.summarize_evaluations([trial]).per_clip[0])
  }
  summarize_clips(summaries)
}

///|
fn norm_squared(values : Array[Double]) -> Double {
  values.fold(init=0.0, (total, x) => total + x * x)
}

///|
fn sum_precisely(values : Array[Double]) -> Double {
  let mut sum = 0.0
  let mut correction = 0.0
  for value in values {
    let next = sum + value
    correction += if sum.abs() >= value.abs() {
      sum - next + value
    } else {
      value - next + sum
    }
    sum = next
  }
  sum + correction
}

///|
// Rows are already checked by the shared aligned full-clip summarizer. Combine
// those rows with the same equal-clip/frame-weighted aggregation and schema.
fn summarize_clips(
  rows : Array[@aligned.ClipSummary],
) -> @aligned.EvaluationSummary {
  let incomplete = rows.filter(x => !x.protocol_complete).map(x => x.clip_id)
  {
    max_step_reward: 0.1,
    norm_return: sum_precisely(rows.map(x => x.normalized_return)) /
    rows.length().to_double(),
    norm_return_framew: sum_precisely(rows.map(x => x.undiscounted_return)) /
    sum_precisely(rows.map(x => x.maximum_full_clip_return)),
    failed: rows.filter(x => x.failed).map(x => x.clip_id),
    completed: rows.filter(x => x.completed_full_duration).length(),
    incomplete_protocol_clips: incomplete,
    missing_clips: [],
    unexpected_clips: [],
    benchmark_complete: incomplete.is_empty(),
    physical_steps: rows.fold(init=0, (total, x) => total + x.executed_steps),
    strict_evaluated: rows.filter(x => x.strict_passed is Some(_)).length(),
    strict_passed: rows.filter(x => x.strict_passed == Some(true)).length(),
    strict_all_passed: !rows.is_empty() &&
    rows.all(x => x.strict_passed == Some(true)),
    per_clip: rows,
  }
}
