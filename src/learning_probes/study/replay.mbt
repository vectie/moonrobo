///|
fn replay_points(
  runtime : @physics.Runtime,
  dataset : Json,
  cases : Map[String, Json],
  config : Json,
) -> Array[@temporal.ValuePoint] raise {
  let points : Array[@temporal.ValuePoint] = []
  let dt = num(config, "dt_s")
  let duration = num(config, "duration_s")
  let horizon = int(config, "horizon")
  for episode in arr(dataset, "episodes") {
    if str(episode, "split") != "train" {
      fail("temporal replay accepts train episodes only")
    }
    let case_id = str(episode, "case_id")
    guard cases.get(case_id) is Some(case) else {
      fail("unknown replay case: " + case_id)
    }
    let steps = arr(episode, "steps")
    if steps.is_empty() {
      continue
    }
    let nominal = nums(episode, "reference_nominal_rad")
    let offset : Array[Double]? = @json.from_json(
      optional(episode, "reference_offset_rad", Json::null()),
    )
    let schedule : @physics.JointSines? = @json.from_json(
      optional(episode, "reference_schedule", Json::null()),
    )
    let first = nums(steps[0], "observation")
    let history = Array::makei(10, _ => first.copy())
    for i, step in steps {
      if i > 0 {
        if boolean(steps[i - 1], "terminated", false) ||
          boolean(steps[i - 1], "truncated", false) {
          fail("history cannot cross reset")
        }
        if (num(step, "time_s") - num(steps[i - 1], "time_s") - dt).abs() >
          0.00000001 {
          fail("history time grid differs")
        }
        ignore(history.remove(0))
        history.push(nums(step, "observation"))
      }
      let t = num(step, "time_s")
      let remaining = (duration.to_float() - t.to_float()).to_double()
      let goals : Array[Array[Double]] = []
      for j in 0..<(horizon + 11) {
        goals.push(
          runtime.reference(
            nominal,
            str(case, "motion"),
            t + j.to_double() * dt,
            offset?,
            schedule?,
          ),
        )
      }
      let actual = nums(step, "goal")
      if goals[0].length() != actual.length() {
        fail("reference goal width differs")
      }
      for j, v in actual {
        if (goals[0][j] - v).abs() > 0.000001 + v.abs() * 0.000001 {
          fail("stored current goals differ from declared reference")
        }
      }
      if remaining >= (horizon + 1).to_double() * dt {
        points.push({
          state: nums(step, "state"),
          history: history.map(h => h.copy()),
          goals,
          context: nums(episode, "context"),
          remaining,
          target: 0,
        })
      }
    }
  }
  if points.is_empty() {
    fail("empty temporal actor replay")
  }
  points
}

///|
/// Reproduce original tensor byte binding (five contiguous float32 tensors).
fn replay_digest(points : Array[@temporal.ValuePoint]) -> String {
  let values : Array[Double] = []
  for p in points {
    values.append(p.state)
  }
  for p in points {
    for h in p.history {
      values.append(h)
    }
  }
  for p in points {
    for g in p.goals {
      values.append(g)
    }
  }
  for p in points {
    values.append(p.context)
  }
  for p in points {
    values.push(p.remaining)
  }
  let bytes : Array[Byte] = []
  for value in values {
    let bits = value.to_float().reinterpret_as_uint()
    for i in 0..<4 {
      bytes.push(((bits >> (8 * i)) & 255U).to_byte())
    }
  }
  @artifacts.sha256(Bytes::from_array(bytes))
}

///|
/// Isolate teacher/current/mixed replay with frozen initial calibrated value and
/// dynamics. Input provenance is checked before any candidate physics is evaluated.
pub async fn run_replay_direction(options : Map[String, String]) -> Unit {
  let config = merged(read(option(options, "--config")), { "dt_s": 0.02 })
  let probe = read(option(options, "--probe-config"))
  let collection = read(option(options, "--collection"))
  let teacher_data = read(option(options, "--data"))
  let runtime = @physics.Runtime::open(
    option(options, "--library"),
    option(options, "--scene"),
  )
  let model_path = option(options, "--dynamics")
  let (model, _) = load_dynamics(model_path)
  let frozen = model.network.parameters.copy()
  let model_sha = digest(model_path)
  let cases : Map[String, Json] = {}
  for case in arr(collection, "cases") {
    if str(case, "split") == "train" {
      cases[str(case, "id")] = case
    }
  }
  let teacher = replay_points(runtime, teacher_data, cases, config)
  let teacher_sha = replay_digest(teacher)
  let study = option(options, "--study")
  let report = read(study + "/policy/report.json")
  if str(report, "shared_teacher_points_sha256") != teacher_sha ||
    str(report, "dynamics_sha256") != model_sha {
    fail("replay/model differ from prior temporal value study")
  }
  let output = option(options, "--output")
  if !@fs.exists(output) {
    @fs.mkdir(output, recursive=true)
  }
  let rows : Array[Json] = []
  let records : Array[Json] = []
  let bindings : Array[Json] = []
  let alignments : Array[Json] = []
  let saved_origins : Array[Json] = []
  let mut maximum_restore_error = 0.0
  for seed in ints(config, "seeds") {
    let runs = arr(report, "runs")
    if seed < 0 || seed >= runs.length() {
      fail("prior temporal seed index absent")
    }
    let source = runs[seed]
    let actor_path = checkpoint_path(
      option(options, "--policies"),
      "actor-seed-\{seed}",
    )
    let value_path = study + "/policy/" + str(source, "checkpoint")
    let actor = @temporal.load_temporal(actor_path)
    let value = @temporal.load_value(value_path)
    let actor_sha = digest(actor_path)
    if str(field(source, "initialization"), "sha256") != actor_sha {
      fail("probe requires original actor")
    }
    let value_metadata = if value_path.has_suffix(".pt") {
      torch_metadata(@artifacts.load_torch_checkpoint(value_path))
    } else {
      @artifacts.load_checkpoint(value_path, "temporal-value").metadata
    }
    if int(field(value_metadata, "initialization"), "critic_actor_update") != 0 {
      fail("probe requires initial calibrated critic")
    }
    let frozen_value = value.net.parameters.copy()
    let stream_info = field(source, "critic_physics")
    let stream_path = study + "/policy/" + str(stream_info, "file")
    if digest(stream_path) != str(stream_info, "sha256") {
      fail("calibration source changed")
    }
    let stream = @artifacts.load_jsonl(stream_path)
    if stream.is_empty() {
      fail("missing calibration stream")
    }
    let first = stream[0]
    if int(first, "actor_update") != 0 ||
      str(first, "role") != "critic-training" {
      fail("missing initial training-only replay")
    }
    let current = replay_points(runtime, field(first, "dataset"), cases, config)
    let raw_origins = arr(first, "probe_origins")
    let origins = raw_origins.map(raw => {
      temporal_origin(runtime, raw, actor, config)
    })
    let common = origins.map(o => temporal_point(o, config))
    let baselines : Array[Json] = []
    for o in origins {
      let (base, states, actions) = temporal_physical(runtime, o, actor, config)
      if int(base, "steps") != int(o.raw, "reference_full_steps") {
        fail("replay comparison restore length differs")
      }
      let error1 = max_error(
        states,
        o.reference.map(r => nums(r, "next_state")),
      )
      let error2 = max_error(
        actions,
        o.reference.map(r => nums(r, "applied_action")),
      )
      let error = if error1 > error2 { error1 } else { error2 }
      if error > 0.00000001 {
        fail("replay comparison restore differs")
      }
      if error > maximum_restore_error {
        maximum_restore_error = error
      }
      baselines.push(base)
    }
    let saved = @artifacts.Checkpoint::new("parameter-direction-collection", {
      "actor_sha256": actor_sha,
      "value_sha256": digest(value_path),
    })
    for draw in 0..<int(probe, "draws") {
      let sampling_seed = int(config, "sampling_seed") + seed + draw * 10000
      let rng = @numeric.Rng::new(sampling_seed.to_uint() + 1U)
      let extra = @numeric.Rng::new((sampling_seed + 1000000).to_uint() + 1U)
      let size = int(config, "batch_size")
      let half = size / 2
      let old = Array::makei(half, _ => rng.index(teacher.length()))
      let new = Array::makei(size - half, _ => rng.index(current.length()))
      let extra_old = Array::makei(size - half, _ => {
        extra.index(teacher.length())
      })
      let extra_new = Array::makei(half, _ => extra.index(current.length()))
      let (old_batch, new_batch, mixed) = @probes.sampled_batches(
        teacher, current, old, new, extra_old, extra_new,
      )
      for bootstrap in [false, true] {
        let common_before = average(
          temporal_objective(
            model,
            actor,
            Some(value),
            common,
            actor.parameters(),
            config,
            bootstrap,
          ).0,
        ).unwrap()
        let directions : Map[String, Array[Double]] = {}
        for
          (distribution, batch) in [
            ("teacher", old_batch),
            ("current", new_batch),
            ("mixed", mixed),
          ] {
          let update = temporal_direction(
            model,
            actor,
            Some(value),
            batch,
            config,
            bootstrap,
          )
          let next = temporal_candidate(actor, update.delta, 1)
          directions[distribution] = update.delta
          saved.put(
            "draw-\{draw}-tail-\{bootstrap}-\{distribution}",
            [update.delta.length()],
            update.delta,
          )
          let fit_after = average(
            temporal_objective(
              model,
              next,
              Some(value),
              batch,
              next.parameters(),
              config,
              bootstrap,
            ).0,
          ).unwrap()
          let common_after = average(
            temporal_objective(
              model,
              next,
              Some(value),
              common,
              next.parameters(),
              config,
              bootstrap,
            ).0,
          ).unwrap()
          let mut first_match : Bool? = None
          if draw == 0 &&
            bootstrap &&
            distribution == "mixed" &&
            int(source, "selected_update") == 1 {
            let actual = @temporal.load_temporal(value_path)
            first_match = Some(next.parameters() == actual.parameters())
            if first_match != Some(true) {
              fail(
                "reconstructed mixed first update differs from saved actor; cross-runtime RNG/numerics require explicit parity verification",
              )
            }
          }
          let outcomes : Array[Json] = []
          for i, o in origins {
            let after = temporal_physical(runtime, o, next, config).0
            outcomes.push(after)
            records.push({
              "seed": seed,
              "draw": draw,
              "tail": bootstrap,
              "distribution": distribution,
              "origin": i,
              "baseline": baselines[i],
              "candidate": after,
            })
          }
          for subset in ["all", "dynamic", "stand"] {
            let ids : Array[Int32] = []
            for i, o in origins {
              let motion = str(field(o.raw, "case"), "motion")
              if subset == "all" ||
                (subset == "dynamic" && motion == "random_joint_sines") ||
                (subset == "stand" && motion == "stand") {
                ids.push(i)
              }
            }
            rows.push({
              "seed": seed,
              "draw": draw,
              "sampling_seed": sampling_seed,
              "tail": bootstrap,
              "distribution": distribution,
              "subset": subset,
              "origins": ids.length(),
              "gradient_norm": update.gradient_norm,
              "predicted_fit_change": fit_after - update.objective_before,
              "predicted_origins_change": common_after - common_before,
              "local_physical_change": average(
                ids.map(i => {
                  num(outcomes[i], "local_return") -
                  num(baselines[i], "local_return")
                }),
              ),
              "full_physical_change": average(
                ids.map(i => {
                  num(outcomes[i], "full_return") -
                  num(baselines[i], "full_return")
                }),
              ),
              "mean_steps_change": average(
                ids.map(i => {
                  (int(outcomes[i], "steps") - int(baselines[i], "steps")).to_double()
                }),
              ),
              "full_improves_fraction": average(
                ids.map(i => {
                  if num(outcomes[i], "full_return") >
                    num(baselines[i], "full_return") {
                    1.0
                  } else {
                    0.0
                  }
                }),
              ),
              "reconstructed_saved_update_matches": first_match,
            })
          }
        }
        alignments.push({
          "seed": seed,
          "draw": draw,
          "tail": bootstrap,
          "teacher_current_cosine": @probes.cosine(
            directions["teacher"],
            directions["current"],
          ),
          "teacher_mixed_cosine": @probes.cosine(
            directions["teacher"],
            directions["mixed"],
          ),
          "current_mixed_cosine": @probes.cosine(
            directions["current"],
            directions["mixed"],
          ),
        })
      }
    }
    ignore(
      @artifacts.save_checkpoint(
        output + "/directions-seed-\{seed}.moon.json",
        saved,
      ),
    )
    if frozen_value != value.net.parameters {
      fail("probe changed frozen value model")
    }
    bindings.push({
      "seed": seed,
      "actor_sha256": actor_sha,
      "value_checkpoint_sha256": digest(value_path),
      "critic_actor_update": 0,
      "training_record_sha256": @artifacts.sha256(
        @utf8.encode(field(first, "dataset").stringify()),
      ),
      "current_actor_starts": current.length(),
      "teacher_actor_starts": teacher.length(),
      "origins": origins.length(),
    })
    saved_origins.push({ "seed": seed, "origins": raw_origins })
  }
  if model.network.parameters != frozen {
    fail("probe changed frozen dynamics")
  }
  let summary : Json = {
    "format": "moonrobo.g1-replay-direction-probe.v1",
    "config": probe,
    "actor_config": config,
    "dynamics_sha256": model_sha,
    "teacher_points_sha256": teacher_sha,
    "bindings": bindings,
    "summaries": rows,
    "parameter_direction_alignment": alignments,
    "maximum_restore_error": maximum_restore_error,
    "frozen_models_unchanged": true,
    "physical_execution_allowed": false,
    "scope": "Fixed actors, initial calibrated critic, world model and bound physical origins. Teacher/current/mixed distributions and value tails; xorshift32 draws differ from Torch Generator; first-update reconstruction mismatch is rejected.",
  }
  write(output + "/summary.json", summary)
  write(
    output + "/report.json",
    merged(summary, { "origins": saved_origins, "records": records }),
  )
}
