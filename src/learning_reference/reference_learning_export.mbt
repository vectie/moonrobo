///|
pub async fn export_learning_stream(
  study : String,
  runtime : @physics.Runtime,
  emit : (Json) -> Unit,
  legacy_normals? : (Int64, Int32, Int32) -> Array[Array[Double]] raise,
  legacy_indices? : (Int64, Array[(Int32, Int32)]) -> Array[Array[Int32]] raise,
  final_route_verified~ : Bool = false,
) -> Unit {
  let report = @artifacts.load_json(study + "/report.json")
  let charter = @artifacts.load_json(study + "/charter.json")
  let config = json_field(report, "config")
  let references_path = json_text(json_field(charter, "references"))
  guard source_digest(references_path + "/manifest.json") ==
    json_text(json_field(report, "reference_manifest_sha256")) else {
    fail("reference manifest changed after learning")
  }
  let (manifest, references) = load_references(references_path)
  let (_, initial) = load_reference_actor(
    study + "/initial/actor-zero-output.pt",
  )
  let geometry = kinematics_from_spec(initial.kinematics)
  let dt = json_number(json_field(json_field(manifest, "layout"), "dt_s"))
  let records = json_array(json_field(report, "physical_records"))
  let origins : Array[Int32] = []
  for record in records {
    let origin = json_integer(json_field(record, "origin_step"))
    if !origins.contains(origin) {
      origins.push(origin)
    }
  }
  origins.sort()
  let schedule = ReferenceSchedule::new(
    references.map(reference => reference.clip()),
    geometry,
    origins,
    dt,
  )
  let config_format = json_text(json_field(config, "format"))
  guard [
      "moonrobo.g1-reference-learning-charter.v1", "moonrobo.g1-reference-tail-training-charter.v1",
      "moonrobo.g1-reference-state-origin-charter.v1", "moonrobo.g1-reference-extended-training-charter.v1",
      "moonrobo.g1-reference-replay-anchor-charter.v1",
    ].contains(config_format) ||
    (
      config_format == "moonrobo.g1-reference-final-route-training-charter.v1" &&
      final_route_verified
    ) else {
    fail("final-route actor-update-state verification must precede export")
  }
  let native_rng = json_text(
    config_default(report, "rng_semantics", "".to_json()),
  ).contains("native xorshift32")
  verify_learning_protocols(study, report, native_rng, legacy_indices)
  let trials : Map[String, Json] = Map([])
  let evaluated = json_array(json_field(report, "runs")).copy()
  evaluated.push(json_field(report, "initial"))
  for run in evaluated {
    for trial in json_array(json_field(run, "trials")) {
      trials[json_text(json_field(trial, "episode_id"))] = trial
    }
  }
  let actors : Map[String, ReferenceActor] = Map([])
  for record in records {
    let record_native = json_text(
        config_default(record, "rng_backend", "".to_json()),
      ) ==
      "native-xorshift32" ||
      (
        native_rng &&
        json_text(config_default(record, "storage_dtype", "".to_json())) ==
        "float64"
      )
    let behavior = json_field(record, "behavior")
    let key = behavior.stringify()
    if !actors.contains(key) {
      actors[key] = load_behavior_actor(study, behavior)
    }
    let actor = actors[key]
    let arrays = load_record_arrays(study, record)
    let n = json_integer(json_field(record, "steps"))
    let origin = json_integer(json_field(record, "origin_step"))
    let clip = json_integer(json_field(record, "clip_index"))
    guard arrays["state"].dtype == (if record_native { "<f8" } else { "<f4" }) else {
      fail("unexpected physical storage dtype")
    }
    let state = numeric_matrix(arrays, "state")
    let next = numeric_matrix(arrays, "next_state")
    let observation = numeric_matrix(arrays, "observation")
    let actions = numeric_matrix(arrays, "applied_action")
    let latent = numeric_matrix(arrays, "latent")
    let old_mean = numeric_matrix(arrays, "old_mean")
    let archived_features = numeric_matrix(arrays, "actual_features")
    let archived_planned = numeric_matrix(arrays, "reference_features")
    guard state.length() == n && n > 0 else {
      fail("invalid physical transition count")
    }
    for i in 1..<n {
      guard state[i] == next[i - 1] else {
        fail("broken physical state continuity")
      }
    }
    let features = @balance.sequence_features(
      geometry,
      observation,
      dt,
      None,
      @balance.GravityGyro,
    )
    let planned = @balance.sequence_features(
      geometry,
      schedule.clips[clip].goals[origin:origin + n].map(goal => {
        reference_observation(goal)
      }),
      dt,
      None,
      @balance.GravityGyro,
    )
    let history = ReferenceHistory::new(actor.history_length)
    let mut feature_error = 0.0
    let mut reference_error = 0.0
    let mut mean_error = 0.0
    let mut action_error = 0.0
    let mut reward_error = 0.0
    let std = json_number(json_field(record, "action_std"))
    let stride = json_integer(
      config_default(config, "noise_seed_origin_stride", Json(0)),
    )
    let noise_seed = json_integer(json_field(config, "noise_seed_base")) +
      json_integer(json_field(record, "seed")) * 1000000 +
      json_integer(json_field(record, "cycle")) * 1000 +
      clip +
      origin * stride +
      (if json_text(json_field(record, "role")) == "model-diagnostic" {
        50000
      } else {
        0
      })
    let generator = @numeric.Rng::new(noise_seed.reinterpret_as_uint())
    let legacy_noise = if !record_native && std > 0.0 {
      guard legacy_normals is Some(generate) else {
        fail(
          "exact Torch CPU randn replay requires MOONROBO_TORCH_RNG_ADAPTER; native RNG must not certify this archive",
        )
      }
      generate(noise_seed.to_int64(), n, actor.nu)
    } else {
      []
    }
    for i in 0..<n {
      for j, x in features[i] {
        feature_error = feature_error.max((x - archived_features[i][j]).abs())
        reference_error = reference_error.max(
          (planned[i][j] - archived_planned[i][j]).abs(),
        )
      }
      let h = history.push(observation[i])
      let command = schedule.command(clip, origin + i, actor.future_length)
      let mean = actor.latent_mean(
        h,
        command.current,
        command.future,
        command.valid,
      )
      let requested = actor.action_from_latent(
        latent[i],
        h,
        command.current,
        features[i],
        planned[i],
      )
      for j, x in mean {
        mean_error = mean_error.max((x - old_mean[i][j]).abs())
        action_error = action_error.max((requested[j] - actions[i][j]).abs())
        let expected = if record_native {
          old_mean[i][j] + std * generator.normal()
        } else if std == 0.0 {
          old_mean[i][j]
        } else {
          (old_mean[i][j].to_float() +
          std.to_float() * legacy_noise[i][j].to_float()).to_double()
        }
        guard expected == latent[i][j] else {
          fail("saved latent samples disagree with frozen exploration law")
        }
      }
      let reference = schedule.clips[clip]
      let previous = observation[i][observation[i].length() - actor.nu:].to_owned()
      let result = reward_from_geometry(
        geometry,
        next[i],
        actions[i],
        previous,
        reference.positions[origin + i + 1],
        reference.quaternions[origin + i + 1],
        reference.goals[origin + i + 1][:actor.nu].to_owned(),
        dt,
      )
      reward_error = reward_error.max(
        (result.reward - arrays["reward"].values[i]).abs(),
      )
      guard result.fallen == (arrays["terminated"].values[i] != 0.0) else {
        fail("stored shared fall test differs")
      }
    }
    guard feature_error.max(reference_error) <=
      json_number(json_field(config, "maximum_feature_alignment_error")) else {
      fail("saved causal features differ from actual/reference histories")
    }
    guard mean_error <= 0.00008 &&
      action_error <=
      json_number(json_field(config, "maximum_action_alignment_error_rad")) else {
      fail("offline actor logits/actions differ from collected behavior")
    }
    guard reward_error <= 0.000001 else {
      fail("stored shared reward differs from recorded states")
    }
    guard json_field(record, "reference_sha256") ==
      json_field(references[clip].metadata, "sha256") else {
      fail("record references another clip")
    }
    let mut metric_difference = 0.0
    if trials.get(json_text(json_field(record, "episode_id"))) is Some(trial) {
      let traced = trace_trial(
        runtime,
        references[clip],
        record,
        trial,
        arrays,
        false,
        dt,
      )
      let frames = json_array(json_field(traced, "replay"))
      for
        (metric, field) in [
          ("joint_rmse_rad", "joint_rmse_rad"),
          ("body_position_rmse_m", "body_position_error_m"),
          ("root_position_rmse_m", "root_position_error_m"),
          ("root_orientation_rmse_rad", "root_orientation_error_rad"),
        ] {
        let mut total = 0.0
        for frame in frames {
          let x = json_number(json_field(frame, field))
          total += x * x
        }
        metric_difference = metric_difference.max(
          ((total / n.to_double()).sqrt() -
          json_number(json_field(trial, metric))).abs(),
        )
      }
      guard metric_difference <= 0.00001 else {
        fail("quality metrics exceed archive reconstruction tolerance")
      }
    }
    let episode = representative_episode(
      references[clip],
      record,
      arrays,
      dt,
      true,
    )
    let result = dataset(
      runtime, episode, manifest, dt, "New on-policy physics; original reference motion bytes retained separately",
    )
    let verification : Json = {
      "storage_dtype": if record_native {
        "float64"
      } else {
        "float32"
      },
      "feature_error": feature_error,
      "reference_feature_error": reference_error,
      "actor_mean_error": mean_error,
      "applied_action_error_rad": action_error,
      "reward_error": reward_error,
      "maximum_quality_metric_reconstruction_difference": metric_difference,
    }
    emit({ "record": record, "dataset": result, "verification": verification })
  }
}
