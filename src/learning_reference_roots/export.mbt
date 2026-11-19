///|
fn matrix_error(
  actual : Array[Array[Double]],
  expected : Array[Array[Double]],
) -> Double raise {
  guard actual.length() == expected.length() else {
    fail("archive matrix row count differs")
  }
  let mut maximum = 0.0
  for i, row in actual {
    guard row.length() == expected[i].length() else {
      fail("archive matrix channel count differs")
    }
    for j, x in row {
      maximum = maximum.max((x - expected[i][j]).abs())
    }
  }
  maximum
}

///|
/// Strict replay-free export of root direction probes. Every archived action, latent, causal feature, shared reward/fall and prefix/full return is reconstructed before a typed transition is emitted. Original float32 gates remain unchanged.
pub async fn export_stream(
  study : String,
  library : String,
  scene : String,
  emit : (Json) -> Unit,
) -> Unit {
  let report = @artifacts.load_json(study + "/report.json")
  let source = @artifacts.load_json(
    text(report, "source_study") + "/report.json",
  )
  let config = field(source, "config")
  let references_path = text(report, "references")
  guard digest(references_path + "/manifest.json") ==
    text(report, "reference_manifest_sha256") else {
    fail("reference manifest changed")
  }
  let (manifest, references) = @ref.load_references(references_path)
  let initial_path = checkpoint_path(study + "/initial/actor-zero-output")
  let (initial_actor, metadata) = @ref.load_reference_actor(initial_path)
  let geometry = @ref.kinematics_from_spec(metadata.kinematics)
  let native = @ref.config_default(report, "numerical_backend", Json::null()) ==
    "moonbit-float64"
  let clips = references.map(fn(reference) {
    let clip = reference.clip()
    if native {
      clip
    } else {
      (
        {
          goals: clip.goals.map(fn(row) { row.map(r) }),
          positions: clip.positions.map(fn(frame) {
            frame.map(fn(row) { row.map(r) })
          }),
          quaternions: clip.quaternions.map(fn(row) { row.map(r) }),
        } : @ref.ReferenceClip)
    }
  })
  let schedule = @ref.ReferenceSchedule::new(
    clips,
    geometry,
    [0],
    metadata.dt_s,
  )
  let runtime = @physics.Runtime::open(library, scene)
  let returns_by_id : Map[String, Json] = {}
  let baseline_trials = rows(report, "baseline_trials")
  let baseline_returns = rows(report, "baseline_returns")
  guard baseline_trials.length() == baseline_returns.length() else {
    fail("baseline trials/returns differ")
  }
  for i, trial in baseline_trials {
    returns_by_id[text(trial, "episode_id")] = baseline_returns[i]
  }
  for row in rows(report, "runs") {
    guard digest(child(study, text(row, "checkpoint"))) ==
      text(row, "checkpoint_sha256") else {
      fail("root model changed")
    }
    guard digest(child(study, text(row, "direction_file"))) ==
      text(row, "direction_sha256") else {
      fail("root direction changed")
    }
    let critic = field(row, "critic")
    guard digest(text(critic, "file")) == text(critic, "sha256") else {
      fail("root critic changed")
    }
    for outcome in rows(row, "outcomes") {
      guard (number(outcome, "achieved_logit_rms") -
        number(outcome, "logit_rms_target")).abs() <=
        1.0e-5 else {
        fail("probe amplitude disagrees with calibration")
      }
      let trials = rows(outcome, "trials")
      let returns = rows(outcome, "returns")
      guard trials.length() == returns.length() else {
        fail("probe trials/returns differ")
      }
      for i, trial in trials {
        returns_by_id[text(trial, "episode_id")] = returns[i]
      }
    }
  }
  let base = initial_actor.parameters()
  for record in rows(report, "physical_records") {
    let behavior = field(record, "behavior")
    guard number(record, "action_std") == 0.0 &&
      integer(record, "origin_step") == 0 else {
      fail("unexpected probe law")
    }
    let actor_path = child(study, text(behavior, "checkpoint"))
    guard digest(actor_path) == text(behavior, "sha256") else {
      fail("probe actor bytes changed")
    }
    let (actor, _) = @ref.load_reference_actor(actor_path)
    guard actor.parameters() == base else {
      fail("probe base actor differs from root initialization")
    }
    if behavior is Object(fields) &&
      fields.get("direction_file") is Some(String(file)) {
      let direction = @ref.load_parameter_direction(
        child(study, file),
        text(behavior, "direction_sha256"),
        actor,
        text(behavior, "sha256"),
      )
      let coefficient = number(behavior, "coefficient")
      actor.set_parameters(
        Array::makei(base.length(), fn(i) {
          if native {
            base[i] + coefficient * direction[i]
          } else {
            add(base[i], mul(coefficient, direction[i]))
          }
        }),
      )
    }
    let arrays = @ref.load_record_arrays(study, record)
    guard arrays["state"].dtype == (if native { "<f8" } else { "<f4" }) else {
      fail("probe storage dtype differs from declared numerical backend")
    }
    let n = integer(record, "steps")
    let clip = integer(record, "clip_index")
    guard n > 0 &&
      clip >= 0 &&
      clip < references.length() &&
      n <= schedule.length else {
      fail("invalid probe clip/step count")
    }
    let state = @ref.numeric_matrix(arrays, "state")
    let next = @ref.numeric_matrix(arrays, "next_state")
    let obs = @ref.numeric_matrix(arrays, "observation")
    let actions = @ref.numeric_matrix(arrays, "applied_action")
    let latent = @ref.numeric_matrix(arrays, "latent")
    let archived_actual = @ref.numeric_matrix(arrays, "actual_features")
    let archived_desired = @ref.numeric_matrix(arrays, "reference_features")
    guard [
      state.length(),
      next.length(),
      obs.length(),
      actions.length(),
      latent.length(),
      archived_actual.length(),
      archived_desired.length(),
      arrays["reward"].values.length(),
      arrays["terminated"].values.length(),
      arrays["truncated"].values.length(),
    ].all(fn(count) { count == n }) else {
      fail("probe array lengths differ from record")
    }
    for i in 1..<n {
      guard state[i] == next[i - 1] else {
        fail("broken probe state continuity")
      }
    }
    let desired_obs = schedule.clips[clip].goals[:n].map(fn(goal) {
      @ref.reference_observation(goal, nu=actor.nu)
    })
    let actual_features = if native {
      @balance.sequence_features(geometry, obs, schedule.dt, None, GravityGyro)
    } else {
      @float32.sequence_features(geometry, obs, schedule.dt, None, GravityGyro)
    }
    let desired_features = if native {
      @balance.sequence_features(
        geometry,
        desired_obs,
        schedule.dt,
        None,
        GravityGyro,
      )
    } else {
      @float32.sequence_features(
        geometry,
        desired_obs,
        schedule.dt,
        None,
        GravityGyro,
      )
    }
    let feature_error = matrix_error(actual_features, archived_actual).max(
      matrix_error(desired_features, archived_desired),
    )
    let history = @ref.ReferenceHistory::new(actor.history_length)
    let means : Array[Array[Double]] = []
    let predicted_actions : Array[Array[Double]] = []
    let recomputed_rewards : Array[Double] = []
    let mut reward_error = 0.0
    for i in 0..<n {
      let h = history.push(obs[i])
      let command = schedule.command(clip, i, actor.future_length)
      let mean = if native {
        actor.latent_mean(h, command.current, command.future, command.valid)
      } else {
        latent32(actor, h, command)
      }
      let action = if native {
        actor.action_from_latent(
          mean,
          h,
          command.current,
          actual_features[i],
          desired_features[i],
        )
      } else {
        action32(
          actor,
          mean,
          h,
          command.current,
          actual_features[i],
          desired_features[i],
        )
      }
      means.push(mean)
      predicted_actions.push(action)
      let previous = obs[i][obs[i].length() - actor.nu:].to_owned()
      let target = schedule.clips[clip]
      let (reward, fallen) = if native {
        let result = @ref.reward_from_geometry(
          geometry,
          next[i],
          actions[i],
          previous,
          target.positions[i + 1],
          target.quaternions[i + 1],
          target.goals[i + 1][:actor.nu].to_owned(),
          schedule.dt,
        )
        (result.reward, result.fallen)
      } else {
        reward32(
          geometry,
          next[i],
          actions[i],
          previous,
          target.positions[i + 1],
          target.quaternions[i + 1],
          target.goals[i + 1][:actor.nu].to_owned(),
          schedule.dt,
        )
      }
      recomputed_rewards.push(reward)
      reward_error = reward_error.max(
        (reward - arrays["reward"].values[i]).abs(),
      )
      guard fallen == (arrays["terminated"].values[i] != 0.0) else {
        fail("root probe shared fall test mismatch")
      }
    }
    let mean_error = matrix_error(means, latent)
    let action_error = matrix_error(predicted_actions, actions)
    guard mean_error <= 8.0e-5 &&
      action_error <= number(config, "maximum_action_alignment_error_rad") &&
      feature_error <= number(config, "maximum_feature_alignment_error") else {
      fail("saved root policy probe does not reconstruct")
    }
    guard reward_error <= 1.0e-6 else { fail("root probe reward mismatch") }
    guard returns_by_id.get(text(record, "episode_id")) is Some(expected) else {
      fail("probe episode has no declared physical return")
    }
    let returns = @ref.discounted_returns(
      recomputed_rewards,
      number(config, "gamma"),
      32,
    )
    guard (returns.full_return - number(expected, "full_return"))
      .abs()
      .max((returns.prefix_return - number(expected, "prefix_return")).abs()) <=
      1.0e-10 else {
      fail("physical return differs from archived reward")
    }
    let episode = @ref.representative_episode(
      references[clip],
      record,
      arrays,
      schedule.dt,
      true,
    )
    let dataset = @ref.dataset(
      runtime,
      episode,
      manifest,
      schedule.dt,
      "MuJoCo CPU transitions; original procedural references, not mocap or hardware",
    )
    emit({
      "record": record,
      "dataset": dataset,
      "maxima": {
        "actor_mean_error": mean_error,
        "action_error_rad": action_error,
        "feature_error": feature_error,
        "reward_error": reward_error,
      },
    })
  }
}
