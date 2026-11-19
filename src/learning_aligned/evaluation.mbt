///|
pub(all) struct ClipEvaluation {
  clip_id : String
  expected_steps : Int32
  rewards : Array[Double]
  terminated : Bool
  strict_rmse : Map[String, Double]?
  termination_frame : Int32?
} derive(Debug, ToJson)

///|
pub(all) struct ClipSummary {
  clip_id : String
  expected_steps : Int32
  executed_steps : Int32
  undiscounted_return : Double
  maximum_full_clip_return : Double
  normalized_return : Double
  failed : Bool
  completed_full_duration : Bool
  protocol_complete : Bool
  termination_frame : Int32?
  strict_passed : Bool?
  strict_rmse : Map[String, Double]?
} derive(Debug, ToJson)

///|
pub(all) struct EvaluationSummary {
  max_step_reward : Double
  norm_return : Double
  norm_return_framew : Double
  failed : Array[String]
  completed : Int32
  incomplete_protocol_clips : Array[String]
  missing_clips : Array[String]
  unexpected_clips : Array[String]
  benchmark_complete : Bool
  physical_steps : Int32
  strict_evaluated : Int32
  strict_passed : Int32
  strict_all_passed : Bool
  per_clip : Array[ClipSummary]
} derive(Debug, ToJson)

///|
pub fn strict_rmse_limits() -> Map[String, Double] {
  {
    "joint_rmse_rad": 0.03,
    "body_position_rmse_m": 0.05,
    "root_position_rmse_m": 0.05,
    "root_orientation_rmse_rad": 0.1,
  }
}

///|
/// Original evaluation JSON schema, including full-catalog and replica accounting.
pub fn EvaluationSummary::report_json(
  self : EvaluationSummary,
  catalog : Array[String],
  physical_settings : Json,
  simulated_replica_count~ : Int32 = 1,
) -> Json raise {
  guard simulated_replica_count > 0 else {
    fail("evaluation replica count must be positive")
  }
  let rows = self.per_clip.map(row => {
    let index = catalog.search(row.clip_id).unwrap_or(-1)
    let fields : Map[String, Json] = {
      "clip_id": row.clip_id.to_json(),
      "expected_steps": row.expected_steps.to_json(),
      "executed_steps": row.executed_steps.to_json(),
      "undiscounted_return": row.undiscounted_return.to_json(),
      "maximum_full_clip_return": row.maximum_full_clip_return.to_json(),
      "normalized_return": row.normalized_return.to_json(),
      "failed": row.failed.to_json(),
      "completed_full_duration": row.completed_full_duration.to_json(),
      "protocol_complete": row.protocol_complete.to_json(),
      "termination_frame": row.termination_frame.to_json(),
      "metadata": { "clip_index": index.to_json(), "start_frame": 0 },
    }
    if row.strict_rmse is Some(metrics) {
      fields["strict_tracking"] = {
        "rmse": metrics.to_json(),
        "limits": strict_rmse_limits().to_json(),
        "passed": row.strict_passed.unwrap_or(false).to_json(),
      }
    }
    Json::object(fields)
  })
  {
    "format": "moonrobo.supermimic-full-clip-evaluation.v1",
    "protocol": {
      "start_frame": 0,
      "requested_horizon": "entire clip, no episode time limit",
      "failure": "hard reference-relative training termination",
      "normalization": "sum reward / ((frame_count - 1) * max_step_reward)",
      "max_step_reward": self.max_step_reward.to_json(),
      "aggregation": "equal clip mean; separate frame-weighted mean",
      "strict_tracking_is_separate": true,
      "physical_settings": physical_settings,
    },
    "n_clips": rows.length().to_json(),
    "norm_return": self.norm_return.to_json(),
    "norm_return_framew": self.norm_return_framew.to_json(),
    "n_failed": self.failed.length().to_json(),
    "failed": self.failed.to_json(),
    "n_completed": self.completed.to_json(),
    "incomplete_protocol_clips": self.incomplete_protocol_clips.to_json(),
    "missing_clips": self.missing_clips.to_json(),
    "unexpected_clips": self.unexpected_clips.to_json(),
    "benchmark_complete": self.benchmark_complete.to_json(),
    "evaluation_physical_steps": self.physical_steps.to_json(),
    "evaluation_simulated_physical_steps": (self.physical_steps *
    simulated_replica_count).to_json(),
    "catalog_clip_count": catalog.length().to_json(),
    "full_catalog_evaluated": (self.benchmark_complete &&
    self.per_clip.length() == catalog.length() &&
    self.per_clip.all(row => catalog.contains(row.clip_id))).to_json(),
    "strict_tracking": {
      "evaluated_clips": self.strict_evaluated.to_json(),
      "passed_clips": self.strict_passed.to_json(),
      "all_passed": self.strict_all_passed.to_json(),
      "interpretation": "additional engineering gate; not the paper's failure count",
    },
    "per_clip": rows.to_json(),
  }
}

///|
// Neumaier sum retains small terms across large positive/negative reward penalties.
fn precise_sum(xs : Array[Double]) -> Double {
  let mut sum = 0.0
  let mut correction = 0.0
  for x in xs {
    let next = sum + x
    correction += if sum.abs() >= x.abs() {
      sum - next + x
    } else {
      x - next + sum
    }
    sum = next
  }
  sum + correction
}

///|
pub fn summarize_evaluations(
  trials : Array[ClipEvaluation],
  max_step_reward~ : Double = 0.1,
  expected_clip_ids? : Array[String],
) -> EvaluationSummary raise {
  guard !trials.is_empty() && finite(max_step_reward) && max_step_reward > 0.0 else {
    fail("evaluation needs trials and finite positive reward maximum")
  }
  let names : Array[String] = []
  let rows : Array[ClipSummary] = []
  let failed : Array[String] = []
  let incomplete : Array[String] = []
  let mut completed = 0
  let mut steps = 0
  let mut strict_evaluated = 0
  let mut strict_passed = 0
  for trial in trials {
    guard !names.contains(trial.clip_id) else {
      fail("evaluate each clip exactly once")
    }
    names.push(trial.clip_id)
    guard trial.expected_steps > 0 &&
      trial.rewards.length() <= trial.expected_steps &&
      trial.rewards.all(finite) else {
      fail("invalid full-clip transition count or reward")
    }
    let complete = trial.rewards.length() == trial.expected_steps
    let protocol_complete = complete || trial.terminated
    let total = precise_sum(trial.rewards)
    let maximum = trial.expected_steps.to_double() * max_step_reward
    let strict = match trial.strict_rmse {
      None => None
      Some(metrics) => {
        for _, value in metrics {
          guard finite(value) && value >= 0.0 else {
            fail("strict metrics must be finite nonnegative RMSE")
          }
        }
        let mut pass = complete && !trial.terminated
        for key, limit in strict_rmse_limits() {
          match metrics.get(key) {
            Some(value) => pass = pass && value <= limit
            None => pass = false
          }
        }
        strict_evaluated += 1
        if pass {
          strict_passed += 1
        }
        Some(pass)
      }
    }
    if trial.terminated {
      failed.push(trial.clip_id)
    }
    if !protocol_complete {
      incomplete.push(trial.clip_id)
    }
    if complete {
      completed += 1
    }
    steps += trial.rewards.length()
    rows.push({
      clip_id: trial.clip_id,
      expected_steps: trial.expected_steps,
      executed_steps: trial.rewards.length(),
      undiscounted_return: total,
      maximum_full_clip_return: maximum,
      normalized_return: total / maximum,
      failed: trial.terminated,
      completed_full_duration: complete,
      protocol_complete,
      termination_frame: trial.termination_frame,
      strict_passed: strict,
      strict_rmse: trial.strict_rmse,
    })
  }
  let requested = expected_clip_ids.unwrap_or(names)
  let seen : Array[String] = []
  for name in requested {
    guard !seen.contains(name) else { fail("expected clip IDs must be unique") }
    seen.push(name)
  }
  let missing = requested.filter(x => !names.contains(x))
  let unexpected = names.filter(x => !requested.contains(x))
  missing.sort()
  unexpected.sort()
  {
    max_step_reward,
    norm_return: precise_sum(rows.map(x => x.normalized_return)) /
    rows.length().to_double(),
    norm_return_framew: precise_sum(rows.map(x => x.undiscounted_return)) /
    precise_sum(rows.map(x => x.maximum_full_clip_return)),
    failed,
    completed,
    incomplete_protocol_clips: incomplete,
    missing_clips: missing,
    unexpected_clips: unexpected,
    benchmark_complete: incomplete.is_empty() &&
    missing.is_empty() &&
    unexpected.is_empty(),
    physical_steps: steps,
    strict_evaluated,
    strict_passed,
    strict_all_passed: strict_evaluated == rows.length() &&
    strict_passed == rows.length(),
    per_clip: rows,
  }
}

///|
pub(all) struct EvaluationSettings {
  eval_mode : Bool
  auto_reset : Bool
  timeout_disabled : Bool
  observation_noise : Bool
  domain_randomization : Bool
  simulated_replica_count : Int32
} derive(Debug)

///|
pub fn Learner::evaluate(
  self : Learner,
  settings : EvaluationSettings,
  reset_frame : (Int32) -> Unit raise,
  inspect_frame : () -> CollectorFrame raise,
  step_action : (Array[Double]) -> Transition raise,
  clip_indices? : Array[Int32],
  strict_tracking~ : Bool = true,
) -> EvaluationSummary raise {
  guard settings.eval_mode &&
    !settings.auto_reset &&
    settings.timeout_disabled &&
    !settings.observation_noise &&
    !settings.domain_randomization else {
    fail("evaluation requires deterministic full-clip physical settings")
  }
  let clips = clip_indices.unwrap_or(
    Array::makei(self.motion.names.length(), i => i),
  )
  guard !clips.is_empty() else { fail("select nonempty evaluation clips") }
  let seen = Array::make(self.motion.names.length(), false)
  // Reject the entire invalid selection before touching the physical backend.
  for index in clips {
    guard index >= 0 && index < self.motion.names.length() && !seen[index] else {
      fail("select distinct valid evaluation clips")
    }
    seen[index] = true
  }
  let trials : Array[ClipEvaluation] = []
  for index in clips {
    let start = self.motion.clip_start[index]
    let expected_steps = self.motion.clip_end[index] - start
    reset_frame(start)
    let mut history : Array[Array[Double]] = []
    let rewards : Array[Double] = []
    let squared : Map[String, Array[Double]] = Map([])
    for name, _ in strict_rmse_limits() {
      squared[name] = []
    }
    let mut terminated = false
    let mut termination_frame : Int32? = None
    for _ in 0..<expected_steps {
      let current = inspect_frame()
      let obs = observation(
        current.state,
        current.previous,
        current.xi,
        self.default_q,
        self.motion.states[current.frame],
        self.mode,
      )
      history = if history.is_empty() {
        Array::makei(self.config.hist, _ => obs.copy())
      } else {
        let h = history[1:].to_owned()
        h.push(obs)
        h
      }
      let action = self.policy.forward(
        history,
        self.motion.goal(current.frame, self.config.goal_frames),
      )
      let tr = step_action(action)
      rewards.push(tr.r)
      if strict_tracking {
        let state = unflatten_state(tr.s1)
        let reference = self.motion.states[tr.frame + 1]
        squared["joint_rmse_rad"].push(
          square_norm(vec_sub(state.q, reference.q)) / 29.0,
        )
        squared["root_position_rmse_m"].push(
          square_norm(vec_sub(state.p, reference.p)),
        )
        let relative = mat_mul(transpose(state.rotation), reference.rotation)
        let cosine = ((relative[0] + relative[4] + relative[8] - 1.0) / 2.0)
          .max(-1.0)
          .min(1.0)
        let angle = @math.acos(cosine)
        squared["root_orientation_rmse_rad"].push(angle * angle)
        let bodies = self.kin.forward(state)
        let refs = self.motion.bodies[tr.frame + 1]
        squared["body_position_rmse_m"].push(
          Array::makei(bodies.length(), i => {
            square_norm(vec_sub(bodies[i].p, refs[i].p))
          }).fold(init=0.0, (s, x) => s + x) /
          bodies.length().to_double(),
        )
      }
      terminated = tr.terminated
      if terminated {
        termination_frame = Some(rewards.length())
      }
      if tr.done() {
        break
      }
    }
    let strict_rmse = if strict_tracking && !rewards.is_empty() {
      let metrics : Map[String, Double] = Map([])
      for key, values in squared {
        metrics[key] = (precise_sum(values) / values.length().to_double()).sqrt()
      }
      Some(metrics)
    } else {
      None
    }
    trials.push({
      clip_id: self.motion.names[index],
      expected_steps,
      rewards,
      terminated,
      strict_rmse,
      termination_frame,
    })
  }
  summarize_evaluations(
    trials,
    expected_clip_ids=clips.map(i => self.motion.names[i]),
  )
}
