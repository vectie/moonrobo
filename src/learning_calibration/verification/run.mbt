///|
pub(all) struct VerificationRow {
  seed : Int32
  records : Int32
  episodes : Int32
  transitions : Int32
  falls : Int32
  time_limits : Int32
  maximum_applied_action_error : Double
  saturated_behavior_latent_fraction : Double
  mean_tanh_action_sensitivity : Double
} derive(Debug, ToJson)

///|
fn validate_episode(
  episode : @sim.Episode,
  case : @sim.Case,
  nu : Int32,
  state_width : Int32,
) -> Unit raise {
  guard episode.split == "train" &&
    episode.source_family == case.family &&
    episode.case_id == case.id &&
    !episode.steps.is_empty() else {
    fail("PPO physics log includes invalid or non-training episode identity")
  }
  guard episode.reference_nominal_rad.length() == nu &&
    episode.context.all(@numeric.finite) else {
    fail("PPO reference/context dimensions differ")
  }
  for i, step in episode.steps {
    guard @numeric.finite(step.time_s) &&
      step.time_s >= 0.0 &&
      step.state.length() == state_width &&
      step.next_state.length() == state_width &&
      step.applied_action.length() == nu &&
      step.goal.length() == nu &&
      step.observation.length() >= nu else {
      fail("PPO physical transition layout differs")
    }
    if i < episode.steps.length() - 1 {
      guard !step.terminated && !step.truncated else {
        fail("PPO physical episode crosses reset")
      }
    }
    if i > 0 {
      guard step.state == episode.steps[i - 1].next_state else {
        fail("PPO physical episode state continuity differs")
      }
    }
  }
  let last = episode.steps[episode.steps.length() - 1]
  guard last.terminated || last.truncated else {
    fail("PPO finite episode has no terminal boundary")
  }
}

///|
/// Recompute recorded numerical targets only. Loading the genuine model provides
/// its layout/reference schedule; this audit never calls a simulator step/reset.
pub async fn verify(
  study : String,
  incoming : String,
  library : String,
  scene : String,
  output : String,
) -> Json {
  let report = @artifacts.load_json(study + "/policy/report.json")
  let config = field(report, "config")
  let collection = field(report, "collection_experiment")
  let dt = number(collection, "control_dt_s")
  let gamma = number(config, "gamma")
  let duration = number(config, "duration_s")
  let target_height = number(config, "target_height_m")
  guard dt > 0.0 && gamma >= 0.0 && gamma < 1.0 && duration > 0.0 else {
    fail("invalid PPO physical-return configuration")
  }
  let runtime = @sim.Runtime::open(library, scene)
  ignore(runtime.control_substeps(dt))
  let (nq, nv, na, nu) = runtime.dimensions()
  let state_width = nq + nv + na
  let case_entries = array(collection, "cases")
  let cases : Map[String, @sim.Case] = Map([])
  let case_ids : Array[String] = []
  for entry in case_entries {
    let case : @sim.Case = @json.from_json(entry)
    guard case.split == "train" && !cases.contains(case.id) else {
      fail("PPO collection requires distinct training cases")
    }
    cases[case.id] = case
    case_ids.push(case.id)
  }
  guard !cases.is_empty() else { fail("PPO collection has no cases") }
  let expected_model = field(
    runtime.dataset([], text(collection, "source_revision"), dt~),
    "model_ref",
  )
  let rows : Array[VerificationRow] = []
  let seen_seeds : Array[Int32] = []
  for result in array(report, "runs") {
    let seed = integer(result, "seed")
    guard !seen_seeds.contains(seed) else { fail("duplicate PPO run seed") }
    seen_seeds.push(seed)
    let (actor, actor_model, legacy) = load_actor(incoming, seed)
    guard actor.base.body.nq == nq &&
      actor.base.body.q_indices == runtime.q_indices() &&
      actor.base.lower.length() == nu &&
      actor.base.body.v_state_indices == runtime.v_indices().map(i => nq + i) else {
      fail(
        "incoming temporal actor disagrees with compiled physical model layout",
      )
    }
    guard actor.temporal.history_length > 0 &&
      actor.temporal.history_length <= 10 &&
      actor.temporal.future_length <= 10 else {
      fail("temporal actor context exceeds physical value-point reconstruction")
    }
    guard actor_model == expected_model else {
      fail("incoming temporal actor model identity differs from physics logs")
    }
    let log = field(result, "physics_log")
    let records = @artifacts.load_jsonl(
      study + "/policy/" + text(log, "file"),
      expected_sha256=text(log, "sha256"),
    )
    let history = array(result, "history")
    let expected_records = integer(config, "iterations")
    guard records.length() == expected_records &&
      history.length() >= records.length() + 1 else {
      fail("PPO numerical records/history count differs")
    }
    let identifiers : Map[String, Bool] = Map([])
    let mut episodes = 0
    let mut transitions = 0
    let mut falls = 0
    let mut max_action_error = 0.0
    let mut sensitivity = 0.0
    let mut saturated = 0
    let mut latent_count = 0
    for index, record in records {
      let reset_seed : Int64 = @json.from_json(field(record, "reset_seed"))
      let collect_seed : Int64 = @json.from_json(
        field(config, "collect_seed_base"),
      )
      guard integer(record, "iteration") == index + 1 &&
        reset_seed == collect_seed + 10000L * seed.to_int64() + index.to_int64() else {
        fail("PPO reset/collection order differs")
      }
      let dataset = field(record, "dataset")
      guard field(dataset, "format") == "moonrobo.motion-dataset.v1" &&
        field(dataset, "model_ref") == expected_model else {
        fail("PPO dataset format/model identity differs")
      }
      close(number(dataset, "dt_s"), dt, 0.0, 0.0, "control cadence")
      let entries = array(dataset, "episodes")
      let ids : Array[String] = []
      for entry in entries {
        ids.push(text(entry, "case_id"))
      }
      guard ids == case_ids else {
        fail("PPO collection case coverage/order differs")
      }
      let latents = matrix(record, "latent_samples", legacy)
      let means = matrix(record, "behavior_latent_means", legacy)
      let finite_targets = vector(record, "finite_return_targets", legacy)
      let objective_rewards = vector(record, "objective_rewards", legacy)
      let soft_continuation = vector(record, "soft_continuation", legacy)
      let discounted_visitation = vector(
        record, "discounted_visitation", legacy,
      )
      let mut count = 0
      let mut batch_falls = 0
      for entry in entries {
        let raw_episode : @sim.Episode = @json.from_json(entry)
        guard cases.get(raw_episode.case_id) is Some(case) else {
          fail("unknown PPO episode case")
        }
        let episode = cast_episode(raw_episode, legacy)
        validate_episode(episode, case, nu, state_width)
        guard !identifiers.contains(episode.id) else {
          fail("PPO repeated physical episode")
        }
        identifiers[episode.id] = true
        let size = episode.steps.length()
        guard count <= latents.length() - size &&
          count <= means.length() - size &&
          count <= finite_targets.length() - size &&
          count <= objective_rewards.length() - size &&
          count <= soft_continuation.length() - size &&
          count <= discounted_visitation.length() - size else {
          fail("PPO numerical targets/action counts differ")
        }
        let offset : Array[Double]? = match
          optional(entry, "reference_offset_rad") {
          Some(value) =>
            if value == Json::null() {
              None
            } else {
              Some(@json.from_json(value))
            }
          None => None
        }
        let schedule : @sim.JointSines? = match
          optional(entry, "reference_schedule") {
          Some(value) =>
            if value == Json::null() {
              None
            } else {
              Some(@json.from_json(value))
            }
          None => None
        }
        // Validate all schedule shapes before using a non-raising reference callback.
        ignore(
          runtime.reference(
            raw_episode.reference_nominal_rad,
            case.motion,
            0.0,
            offset?,
            schedule?,
          ),
        )
        let reference = (time : Double) => {
          try! runtime.reference(
            raw_episode.reference_nominal_rad,
            case.motion,
            time,
            offset?,
            schedule?,
          )
        }
        let points = @temporal_native.episode_value_points(
          episode, actor, dt, duration, gamma, target_height, reference,
        )
        guard points.length() == size else {
          fail("PPO value point count differs from physical transitions")
        }
        let rewards : Array[Double] = []
        let continuation : Array[Double] = []
        for i, step in episode.steps {
          let point = points[i]
          guard point.history.length() == 10 &&
            point.goals.length() == 11 &&
            point.history[9].length() >= nu else {
            fail("PPO history/preview dimensions differ")
          }
          let goal = finite_row(point.goals[0], legacy)
          let expected_action = latent_setpoint(
            actor,
            latents[count + i],
            goal,
            legacy,
          )
          max_action_error = max_action_error.max(
            checked_row(
              step.applied_action,
              expected_action,
              0.0,
              0.0,
              "applied latent action",
            ),
          )
          let latest = finite_row(point.history[9], legacy)
          let previous = latest[latest.length() - nu:].to_owned()
          if i > 0 {
            ignore(
              checked_row(
                previous,
                episode.steps[i - 1].applied_action,
                0.0,
                0.0,
                "causal previous action",
              ),
            )
          }
          let (reward, alive) = objective(
            step.next_state,
            step.applied_action,
            previous,
            goal,
            actor.base.body.q_indices,
            target_height,
            legacy,
          )
          guard @numeric.finite(reward) &&
            @numeric.finite(alive) &&
            alive >= 0.0 &&
            alive <= 1.0 else {
            fail("invalid recomputed PPO reward/continuation")
          }
          rewards.push(reward)
          continuation.push(alive)
          guard means[count + i].length() == nu else {
            fail("PPO behavior latent width differs")
          }
          for mean in means[count + i] {
            let bounded = rounded(@math.tanh(mean), legacy)
            sensitivity += rounded(
              1.0 - rounded(bounded * bounded, legacy),
              legacy,
            )
            if mean.abs() > 3.0 {
              saturated += 1
            }
            latent_count += 1
          }
        }
        let targets = returns(
          rewards,
          continuation,
          episode.steps.map(s => s.terminated),
          gamma,
          legacy,
        )
        let weights = visitation(continuation, gamma, legacy)
        for i in 0..<size {
          close(
            finite_targets[count + i],
            targets[i],
            0.00001,
            0.000001,
            "finite_return_targets",
          )
          close(
            objective_rewards[count + i],
            rewards[i],
            0.00001,
            0.000001,
            "objective_rewards",
          )
          close(
            soft_continuation[count + i],
            continuation[i],
            0.00001,
            0.000001,
            "soft_continuation",
          )
          close(
            discounted_visitation[count + i],
            weights[i],
            0.00001,
            0.000001,
            "discounted_visitation",
          )
          if !legacy {
            close(
              points[i].target,
              targets[i],
              0.0,
              0.0,
              "shared finite-return reconstruction",
            )
          }
        }
        if episode.steps[size - 1].terminated {
          batch_falls += 1
        }
        count += size
      }
      guard [
        latents.length(),
        means.length(),
        finite_targets.length(),
        objective_rewards.length(),
        soft_continuation.length(),
        discounted_visitation.length(),
      ].all(length => length == count) else {
        fail("PPO numerical targets/action counts differ")
      }
      let update = history[index + 1]
      guard integer(update, "collection_transitions") == count &&
        integer(update, "collection_falls") == batch_falls else {
        fail("PPO history does not match actual sampling")
      }
      episodes += entries.length()
      transitions += count
      falls += batch_falls
    }
    guard records.length() == expected_records &&
      episodes == integer(result, "training_episodes") &&
      transitions == integer(result, "training_transitions") &&
      falls == integer(result, "training_falls") &&
      latent_count > 0 else {
      fail("PPO actual training totals differ")
    }
    rows.push({
      seed,
      records: records.length(),
      episodes,
      transitions,
      falls,
      time_limits: episodes - falls,
      maximum_applied_action_error: max_action_error,
      saturated_behavior_latent_fraction: saturated.to_double() /
      latent_count.to_double(),
      mean_tanh_action_sensitivity: sensitivity / latent_count.to_double(),
    })
  }
  guard !rows.is_empty() else { fail("PPO verification report has no runs") }
  let verified : Json = {
    "format": "moonrobo.g1-temporal-ppo-numerical-verification.v1",
    "rows": rows.to_json(),
    "scope": "Every saved training episode: actual latent-to-setpoint transform, causal previous action, full objective reward, finite MC target and discounted soft-survival visitation. Scalar targets recomputed in physical units; no learned transition inference.",
    "physical_execution_allowed": false,
  }
  ignore(@artifacts.save_json(output, verified))
  verified
}
