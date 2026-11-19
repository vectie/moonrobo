///|
fn teacher_parameters(value : Json) -> @balance.FeedbackParameters raise {
  @balance_physics.parameters_from_json(value)
}

///|
fn collect_teacher_labels(
  runtime : @native_physics.Runtime,
  actor : @training.Actor,
  collection : Json,
  parameters : @balance.FeedbackParameters,
  reset_base : Int32,
  _rng : @numeric.Rng,
) -> (Array[@native_physics.Episode], Array[@training.TeacherPoint]) raise {
  let cases : Array[Json] = @json.from_json(field(collection, "cases"))
  let episodes = []
  let points : Array[@training.TeacherPoint] = []
  for case_json in cases {
    if text(case_json, "split") != "train" {
      continue
    }
    let case : @native_physics.Case = @json.from_json(case_json)
    for seed in [reset_base, reset_base + 1] {
      let reset_rng = @numeric.Rng::new(seed.to_uint())
      let offset_rng = @numeric.Rng::new(seed.to_uint() ^ 1729U)
      let teacher = @balance_physics.NativeBalanceTeacher::new(
        runtime,
        parameters,
        number(collection, "control_dt_s"),
      )
      let labels = []
      let policy = fn(
        obs : Array[Double],
        goal : Array[Double],
      ) -> Array[Double] {
        labels.push(try! teacher.predict(obs, goal))
        actor.predict(obs, goal)
      }
      let offset = if case.motion == "pose_offset" {
        let limits = field(case_json, "goal_offset_rad")
        Some(
          @native_physics.pose_offset(
            runtime.joint_names(),
            number(limits, "lower"),
            number(limits, "waist"),
            number(limits, "upper"),
            runtime.joint_names().map(_ => 2 * offset_rng.uniform() - 1),
          ),
        )
      } else {
        None
      }
      let schedule = joint_sines(
        runtime,
        case_json,
        @numeric.Rng::new(seed.to_uint() ^ 2718U),
      )
      let (episode, _) = runtime.rollout(
        case,
        seed,
        "policy",
        number(collection, "duration_s"),
        number(collection, "control_dt_s"),
        () => reset_rng.normal(),
        fall_height=number(collection, "fall_height_m"),
        fall_upright=number(collection, "fall_upright_z"),
        policy~,
        offset?,
        schedule?,
      )
      guard labels.length() == episode.steps.length() else {
        fail("teacher label count differs from actual student transitions")
      }
      for i in 0..<labels.length() {
        let step = episode.steps[i]
        points.push({
          observation: step.observation,
          goal: step.goal,
          target: labels[i],
          time_s: step.time_s,
        })
      }
      episodes.push(episode)
    }
  }
  (episodes, points)
}

///|
/// Physical-validation behavior cloning or dataset aggregation. Original applied student actions stay intact in archived physics datasets.
pub async fn run_supervised(
  train_path : String,
  library : String,
  scene : String,
  config_path : String,
  experiment_path : String,
  output : String,
  policies_directory? : String,
  teacher_path? : String,
  collection_path? : String,
) -> Unit {
  let aggregate = policies_directory is Some(_)
  let config = @artifacts.load_json(config_path)
  let experiment = @artifacts.load_json(experiment_path)
  let batch = @artifacts.load_window_batch(train_path, "train")
  guard batch.horizon == 1 else {
    fail("cloning and aggregation require point batches")
  }
  let runtime = @native_physics.Runtime::open(library, scene)
  let (nq, _, _, nu) = runtime.dimensions()
  let body : @training.Body = {
    q_indices: runtime.q_indices(),
    v_state_indices: runtime.v_indices().map(i => nq + i),
    nq,
  }
  let width = batch.observation.length() / batch.count
  let observations = Array::makei(batch.count, i => {
    Array::makei(width, j => batch.observation[i * width + j])
  })
  let goals = Array::makei(batch.count, i => {
    Array::makei(nu, j => batch.goal[i * nu + j])
  })
  let points : Array[@training.TeacherPoint] = Array::makei(batch.count, i => {
    observation: observations[i],
    goal: goals[i],
    target: Array::makei(nu, j => batch.action[i * nu + j]),
    time_s: batch.start_time_s[i],
  })
  let early = points.filter(p => p.time_s < 2)
  guard aggregate || !early.is_empty() else {
    fail("cloning needs early-time samples")
  }
  let windows = @training.windows_from_batch(batch)
  let state_stats = @numeric.fit_normalization(
    windows.map(w => w.state[0]),
    0.1,
  )
  let obs_stats = @numeric.fit_normalization(observations, 0.1)
  let goal_stats = @numeric.fit_normalization(goals, 0.1)
  let (lower, upper) = runtime.control_bounds()
  let cases : Array[Json] = @json.from_json(field(experiment, "cases"))
  let seeds : Array[Int32] = @json.from_json(field(config, "seeds"))
  let validation_seeds : Array[Int32] = @json.from_json(
    field(config, "validation_seeds"),
  )
  let test_seeds : Array[Int32] = @json.from_json(field(config, "test_seeds"))
  let teacher = match teacher_path {
    Some(path) => Some(@artifacts.load_json(path))
    None => None
  }
  let collection = match collection_path {
    Some(path) => @artifacts.load_json(path)
    None => experiment
  }
  let teacher_sha = match teacher_path {
    Some(path) => @artifacts.sha256(@fs.read_file(path).binary())
    None => ""
  }
  if aggregate {
    guard teacher is Some(teacher) else {
      fail("dataset aggregation needs teacher parameters")
    }
    let original_teacher = @fs.read_file(
      "providers/motion_learning/balance_teacher.py",
    ).binary()
    guard field(teacher, "provider_sha256") ==
      @artifacts.sha256(original_teacher).to_json() else {
      fail(
        "teacher fitted Python source digest differs; cross-language parity still requires validation",
      )
    }
  }
  if !@fs.exists(output) {
    @fs.mkdir(output)
  }
  let runs : Array[Json] = []
  for seed in seeds {
    let rng = @numeric.Rng::new(seed.to_uint())
    let prior = match policies_directory {
      Some(dir) =>
        Some(
          @training.load_learning_checkpoint(actor_path(dir, seed), "g1-actor"),
        )
      None => None
    }
    let actor = match prior {
      Some(checkpoint) => @training.actor_from_checkpoint(checkpoint)
      None =>
        @training.Actor::new(
          obs_stats,
          goal_stats,
          lower,
          upper,
          number(config, "action_delta_rad"),
          body,
          integer(config, "hidden_width"),
          rng,
        )
    }
    guard actor.body.q_indices == body.q_indices &&
      actor.body.v_state_indices == body.v_state_indices &&
      actor.body.nq == body.nq else {
      fail("supervised actor body differs from physical runtime")
    }
    let critic = match prior {
      Some(checkpoint) =>
        @training.critic_from_actor_checkpoint(
          checkpoint,
          nu,
          windows[0].context.length(),
        )
      None =>
        @training.Critic::new(
          state_stats,
          nu,
          windows[0].context.length(),
          number(config, "gamma"),
          rng,
          translation_invariant=optional_bool(
            config, "critic_horizontal_translation_invariant", false,
          ),
          zero_output=true,
        )
    }
    let optimizer = @numeric.Adam::new(
      actor.network.parameters.length(),
      number(config, "actor_learning_rate"),
    )
    let initial_parameters = actor.network.parameters.copy()
    let (initial, _, _) = evaluate(
      runtime,
      cases,
      validation_seeds,
      experiment,
      Some(actor),
      "validation",
      @numeric.Rng::new(2718U),
    )
    let mut best = initial
    let mut best_parameters = actor.network.parameters.copy()
    let mut selected = 0
    let history : Array[Json] = [
      { "update": 0, "validation": summary_json(initial) },
    ]
    let recent : Array[@training.TeacherPoint] = []
    let streams : Array[Json] = []
    let updates = if aggregate {
      integer(config, "rounds")
    } else {
      integer(config, "updates")
    }
    let batch_size = integer(config, "batch_size")
    let evaluation_updates : Array[Int32] = if aggregate {
      []
    } else {
      @json.from_json(field(config, "evaluation_updates"))
    }
    let start_time = @async.now()
    for update in 1..<=updates {
      if aggregate {
        let parameters = teacher_parameters(
          field(teacher.unwrap(), "parameters"),
        )
        let reset_base = integer(config, "collection_seed_base") +
          seed * 10000 +
          (update - 1) * 2
        let (episodes, fresh) = collect_teacher_labels(
          runtime, actor, collection, parameters, reset_base, rng,
        )
        guard !fresh.is_empty() else {
          fail("aggregation collected no teacher labels")
        }
        recent.append(fresh)
        while recent.length() > integer(config, "recent_points") {
          ignore(recent.remove(0))
        }
        let digest = @artifacts.sha256(
          @utf8.encode(actor.network.parameters.to_json().stringify()),
        )
        let versioned_episodes = episodes.map(e => {
          ..e,
          id: e.id + "-aggregation-" + (update - 1).to_string() + "-" + digest,
        })
        streams.push({
          "round": update.to_json(),
          "policy_state_sha256": digest.to_json(),
          "teacher_sha256": teacher_sha.to_json(),
          "dataset": runtime.dataset(
            versioned_episodes,
            text(collection, "source_revision"),
            dt=number(collection, "control_dt_s"),
          ),
          "teacher_action_targets": fresh.map(p => p.target).to_json(),
          "target_order": "episode order, then step order; applied_action is student control",
        })
      }
      let count = if aggregate {
        integer(config, "updates_per_round")
      } else {
        1
      }
      let mut loss = 0.0
      for _ in 0..<count {
        let mini = Array::makei(batch_size, i => {
          if i < batch_size / 2 {
            points[rng.index(points.length())]
          } else if aggregate {
            recent[rng.index(recent.length())]
          } else {
            early[rng.index(early.length())]
          }
        })
        loss = actor.clone_update(optimizer, mini)
      }
      if aggregate || evaluation_updates.contains(update) {
        let (current, _, _) = evaluate(
          runtime,
          cases,
          validation_seeds,
          experiment,
          Some(actor),
          "validation",
          @numeric.Rng::new(2718U),
        )
        history.push({
          "update": update.to_json(),
          "action_loss": loss.to_json(),
          "validation": summary_json(current),
          "recent_points": recent.length().to_json(),
        })
        if @training.ranks_above(current, best) {
          best = current
          best_parameters = actor.network.parameters.copy()
          selected = update
        }
      }
    }
    let training_seconds = (@async.now() - start_time).to_double() / 1000
    let actual_selected = if aggregate {
      selected * integer(config, "updates_per_round")
    } else {
      selected
    }
    let metadata : Json = {
      "config": config,
      "seed": seed.to_json(),
      "training_batch_sha256": batch.digest.to_json(),
      "selected_update": actual_selected.to_json(),
      "training_kind": (if aggregate {
        "dataset-aggregation"
      } else {
        "behavior-cloning"
      }).to_json(),
      "critic_status": "untrained-zero-output",
      "teacher_sha256": teacher_sha.to_json(),
      "model_ref": field(batch.layout, "model_ref"),
    }
    let latest_update = if aggregate {
      updates * integer(config, "updates_per_round")
    } else {
      updates
    }
    let latest = actor.checkpoint(metadata_update(metadata, latest_update))
    critic.put_checkpoint(latest)
    let latest_name = "latest-actor-seed-" + seed.to_string() + ".moon.json"
    ignore(@artifacts.save_checkpoint(output + "/" + latest_name, latest))
    let changed = best_parameters != initial_parameters
    @training.restore_parameters(actor.network, best_parameters)
    let selected_checkpoint = actor.checkpoint(metadata)
    critic.put_checkpoint(selected_checkpoint)
    let name = "actor-seed-" + seed.to_string() + ".moon.json"
    let sha = @artifacts.save_checkpoint(
      output + "/" + name,
      selected_checkpoint,
    )
    let restored = @training.actor_from_checkpoint(
      @training.load_learning_checkpoint(
        output + "/" + name,
        "g1-actor",
        expected_sha256=sha,
      ),
    )
    guard restored.predict(observations[0], goals[0]) ==
      actor.predict(observations[0], goals[0]) else {
      fail("supervised checkpoint reload differs")
    }
    let training_action_rmse : Double? = if aggregate {
      None
    } else {
      let mut squared_error = 0.0
      let mut elements = 0
      for point in points {
        let predicted = restored.predict(point.observation, point.goal)
        guard predicted.length() == point.target.length() else {
          fail("cloning RMSE action width differs")
        }
        for j in 0..<predicted.length() {
          let error = predicted[j] - point.target[j]
          squared_error += error * error
          elements += 1
        }
      }
      guard elements > 0 && @numeric.finite(squared_error) else {
        fail("cloning RMSE needs finite nonempty predictions")
      }
      Some((squared_error / elements.to_double()).sqrt())
    }
    let (candidate, episodes, trials) = evaluate(
      runtime,
      cases,
      test_seeds,
      experiment,
      Some(restored),
      "all",
      @numeric.Rng::new(31415U),
    )
    let (baseline, _, baseline_trials) = evaluate(
      runtime,
      cases,
      test_seeds,
      experiment,
      None,
      "all",
      @numeric.Rng::new(31415U),
    )
    ignore(
      @artifacts.save_json(
        output + "/physics-seed-" + seed.to_string() + ".json",
        {
          "candidate": physics_group(candidate, trials),
          "baseline": physics_group(baseline, baseline_trials),
          "trials": trials.to_json(),
        },
      ),
    )
    ignore(
      @artifacts.save_json(
        output + "/candidate-data-seed-" + seed.to_string() + ".json",
        runtime.dataset(
          episodes,
          text(experiment, "source_revision"),
          dt=number(experiment, "control_dt_s"),
        ),
      ),
    )
    let stream_sha = if aggregate {
      @artifacts.save_jsonl(
        output + "/student-physics-seed-" + seed.to_string() + ".jsonl.gz",
        streams,
      )
    } else {
      ""
    }
    runs.push({
      "seed": seed.to_json(),
      "selected_update": actual_selected.to_json(),
      "selected_round": selected.to_json(),
      "training_seconds": training_seconds.to_json(),
      "training_action_rmse_rad": training_action_rmse.to_json(),
      "checkpoint": name.to_json(),
      "latest_checkpoint": latest_name.to_json(),
      "checkpoint_sha256": sha.to_json(),
      "actor_changed": changed.to_json(),
      "candidate": counted_summary(candidate, trials.length()),
      "baseline": counted_summary(baseline, baseline_trials.length()),
      "history": history.to_json(),
      "student_physics_sha256": stream_sha.to_json(),
      "qualifies": @training.qualifies(
        candidate,
        optional_number(config, "max_mean_joint_rmse_rad", 1.0 / 0.0),
      ).to_json(),
      "reload_matches": true,
    })
  }
  ignore(
    @artifacts.save_json(output + "/report.json", {
      "format": "moonrobo.moonbit-supervised-fit.v1",
      "training_kind": (if aggregate {
        "dataset-aggregation"
      } else {
        "behavior-cloning"
      }).to_json(),
      "config": config,
      "runs": runs.to_json(),
      "training_batch_sha256": batch.digest.to_json(),
      "physical_execution_allowed": false,
      "parity_status": "awaiting-python-comparison",
    }),
  )
}
