///|
/// Native workflow adapter. Configurations retain the historical study keys;
/// checkpoint bytes use explicit .moon.json names and source provenance.
fn study_field(value : Json, key : String) -> Json raise {
  guard value is Object(fields) && fields.get(key) is Some(found) else {
    fail("missing study field: " + key)
  }
  found
}

///|
fn study_num(value : Json, key : String) -> Double raise {
  @json.from_json(study_field(value, key))
}

///|
fn study_int(value : Json, key : String) -> Int32 raise {
  @json.from_json(study_field(value, key))
}

///|
fn study_text(value : Json, key : String) -> String raise {
  @json.from_json(study_field(value, key))
}

///|
fn study_opt(args : Array[String], key : String) -> String? raise {
  let matches = args.filter(fn(x) { x == key })
  guard matches.length() <= 1 else {
    fail("duplicate native study option: " + key)
  }
  for i, x in args {
    if x == key {
      guard i + 1 < args.length() else { fail("missing option value") }
      return Some(args[i + 1])
    }
  }
  None
}

///|
fn study_arg(args : Array[String], key : String) -> String raise {
  guard study_opt(args, key) is Some(value) else {
    fail("required native study option: " + key)
  }
  value
}

///|
pub async fn study_checkpoint(
  folder : String,
  prefix : String,
  seed : Int32,
) -> String {
  let native = folder + "/" + prefix + "-seed-\{seed}.moon.json"
  if @fs.exists(native) {
    return native
  }
  let legacy = folder + "/" + prefix + "-seed-\{seed}.pt"
  guard @fs.exists(legacy) else {
    fail("missing native or reference checkpoint: " + native)
  }
  legacy
}

///|
fn study_cases(experiment : Json, train : Bool) -> Array[Json] raise {
  let all : Array[Json] = @json.from_json(study_field(experiment, "cases"))
  if train {
    all.filter(fn(item) { try! (study_text(item, "split") == "train") })
  } else {
    all
  }
}

///|
fn study_summary(trials : Array[@native_physics.Trial]) -> Json raise {
  @balance.summarize_recorded_trials(trials.map(fn(t) { t.to_json() }))
}

///|
/// Schedules are sampled separately for each declared episode reset, rather
/// than shared across cases or reused across independent evaluation seeds.
fn study_evaluate(
  runtime : @native_physics.Runtime,
  actor : @temporal.TemporalPolicy,
  experiment : Json,
  seeds : Array[Int32],
  split : String?,
) -> Json raise {
  let trials : Array[@native_physics.Trial] = []
  for raw in study_cases(experiment, false) {
    let case : @native_physics.Case = @json.from_json(raw)
    if split is Some(wanted) && case.split != wanted {
      continue
    }
    for seed in seeds {
      let (offset, schedule) = @balance_native.sample_reference(
        runtime, raw, seed,
      )
      let (_, trial) = rollout(
        runtime,
        actor,
        case,
        seed,
        study_num(experiment, "duration_s"),
        study_num(experiment, "control_dt_s"),
        @numeric.Rng::new(seed.to_uint()),
        offset?,
        schedule?,
        fall_height=study_num(experiment, "fall_height_m"),
        fall_upright=study_num(experiment, "fall_upright_z"),
      )
      trials.push(trial)
    }
  }
  { "summary": study_summary(trials), "trials": trials.to_json() }
}

///|
fn study_better(a : Json, b : Json) -> Bool raise {
  let a = study_field(a, "summary")
  let b = study_field(b, "summary")
  let fa = study_num(a, "falls")
  let fb = study_num(b, "falls")
  if fa != fb {
    return fa < fb
  }
  let sa = study_num(a, "mean_survival_s")
  let sb = study_num(b, "mean_survival_s")
  if sa != sb {
    return sa > sb
  }
  study_num(a, "mean_joint_rmse_rad") < study_num(b, "mean_joint_rmse_rad")
}

///|
fn study_qualifies(
  summary : Json,
  config : Json,
  _seconds : Double,
) -> Bool raise {
  guard config is Object(fields) else {
    fail("configuration must be an object")
  }
  let within = match fields.get("max_mean_joint_rmse_rad") {
    Some(value) =>
      study_num(summary, "mean_joint_rmse_rad") <=
      (@json.from_json(value) : Double)
    None => true
  }
  study_num(summary, "falls") == 0.0 && within
}

///|
fn study_base_evaluate(
  runtime : @native_physics.Runtime,
  base : @training.Actor?,
  experiment : Json,
  seeds : Array[Int32],
  split : String?,
) -> Json raise {
  let trials : Array[@native_physics.Trial] = []
  for raw in study_cases(experiment, false) {
    let case : @native_physics.Case = @json.from_json(raw)
    if split is Some(wanted) && case.split != wanted {
      continue
    }
    for seed in seeds {
      let (offset, schedule) = @balance_native.sample_reference(
        runtime, raw, seed,
      )
      let rng = @numeric.Rng::new(seed.to_uint())
      let policy = base.map(fn(actor) {
        fn(obs, goal) { actor.predict(obs, goal) }
      })
      let (_, trial) = runtime.rollout(
        case,
        seed,
        if base.is_some() {
          "policy"
        } else {
          "position"
        },
        study_num(experiment, "duration_s"),
        study_num(experiment, "control_dt_s"),
        fn() { rng.normal() },
        policy?,
        offset?,
        schedule?,
        fall_height=study_num(experiment, "fall_height_m"),
        fall_upright=study_num(experiment, "fall_upright_z"),
      )
      trials.push(trial)
    }
  }
  { "summary": study_summary(trials), "trials": trials.to_json() }
}

///|
fn study_points(
  runtime : @native_physics.Runtime,
  data : Json,
  collection : Json,
  h : Int32,
  f : Int32,
) -> Array[@temporal.TemporalPoint] raise {
  let episodes : Array[Json] = @json.from_json(study_field(data, "episodes"))
  let cases = study_cases(collection, true)
  let result : Array[@temporal.TemporalPoint] = []
  let dt = study_num(collection, "control_dt_s")
  for stored in episodes {
    let episode : @native_physics.Episode = @json.from_json(stored)
    guard episode.split == "train" else {
      fail("supervised data contains held-out episodes")
    }
    let matched = cases.filter(fn(c) {
      try! (study_text(c, "id") == episode.case_id)
    })
    guard matched.length() == 1 else {
      fail("episode case not unique in train collection")
    }
    let raw = matched[0]
    let case : @native_physics.Case = @json.from_json(raw)
    guard stored is Object(fields) else { fail("episode must be an object") }
    let offset : Array[Double]? = match fields.get("reference_offset_rad") {
      Some(Null) | None => None
      Some(value) => Some(@json.from_json(value))
    }
    let schedule : @native_physics.JointSines? = match
      fields.get("reference_schedule") {
      Some(Null) | None => None
      Some(value) => Some(@json.from_json(value))
    }
    guard case.motion != "pose_offset" || offset.is_some() else {
      fail("dynamic teacher data must preserve its actual reference offset")
    }
    guard case.motion != "random_joint_sines" || schedule.is_some() else {
      fail(
        "dynamic teacher data must preserve its actual reference schedule; do not resample legacy RNG",
      )
    }
    let reference = fn(time) {
      try! runtime.reference(
        episode.reference_nominal_rad,
        case.motion,
        time,
        offset?,
        schedule?,
      )
    }
    result.append(episode_points(episode, h, f, dt, reference))
  }
  guard !result.is_empty() else { fail("empty temporal supervision") }
  result
}

///|
/// Record the actual deterministic native reference associated with each
/// episode. Stored schedules let future consumers read old and native data
/// without substituting one language's random stream for another's.
fn study_dataset(
  runtime : @native_physics.Runtime,
  episodes : Array[@native_physics.Episode],
  collection : Json,
) -> Json raise {
  let cases = study_cases(collection, false)
  let rows = episodes.map(fn(episode) raise {
    let matched = cases.filter(fn(raw) {
      try! (study_text(raw, "id") == episode.case_id)
    })
    guard matched.length() == 1 else {
      fail("dataset episode case must be unique")
    }
    let suffix = episode.id.split("-seed-").to_array()
    guard suffix.length() == 2 else {
      fail("native episode ID must contain one reset seed")
    }
    let seed = @string.parse_int(suffix[1].split("-").to_array()[0])
    let (offset, schedule) = @balance_native.sample_reference(
      runtime,
      matched[0],
      seed,
    )
    guard episode.to_json() is Object(fields) else {
      fail("invalid episode encoding")
    }
    fields["reference_offset_rad"] = offset.to_json()
    fields["reference_schedule"] = schedule.to_json()
    Json::object(fields)
  })
  runtime.dataset(
    episodes,
    study_text(collection, "source_revision"),
    dt=study_num(collection, "control_dt_s"),
    episode_json=rows,
  )
}

///|
/// Preserve source identity and ordinary parent metadata without carrying a
/// stale paired critic forward into an unrelated actor update.
pub fn temporal_metadata(
  parent : Json,
  config : Json,
  actor : @temporal.TemporalPolicy,
  update : Int32,
  evidence : Json,
  critic_status~ : String = "not-trained",
) -> Json raise {
  guard parent is Object(fields) else {
    fail("incoming actor metadata must be an object")
  }
  let model_ref = study_field(parent, "model_ref")
  guard model_ref is String(identity) && !identity.is_empty() else {
    fail("incoming actor requires real model_ref binding")
  }
  let base_config = fields
    .get("base_config")
    .unwrap_or_else(fn() { try! study_field(parent, "config") })
  let result = fields.copy()
  ignore(result.remove("temporal_value_checkpoint"))
  result["base_config"] = base_config
  result["model_ref"] = model_ref
  result["config"] = config
  result["selected_update"] = update.to_json()
  result["initialization"] = evidence
  result["history_length"] = actor.temporal.history_length.to_json()
  result["future_length"] = actor.temporal.future_length.to_json()
  result["adapter_width"] = actor.temporal.adapter.dimensions[1].to_json()
  result["critic_status"] = critic_status.to_json()
  result["source_language"] = "moonbit"
  Json::object(result)
}

///|
pub async fn temporal_parent_metadata(path : String) -> Json {
  if path.has_suffix(".pt") {
    @training.torch_checkpoint_metadata(@artifacts.load_torch_checkpoint(path))
  } else {
    @artifacts.load_checkpoint(path, "temporal-actor").metadata
  }
}

///|
/// Full original supervised study: train-only teacher collection, zero adapter
/// identity, causal relabeling, mixed half-old/half-recent batches, validation
/// selection including round zero, checkpoint reload and independent test.
pub async fn run_supervised_study(
  args : Array[String],
  library : String,
  scene : String,
  provider_source : String,
) -> Unit {
  guard args.length() > 1 else { fail("temporal training command required") }
  let command = args[1]
  let config = @artifacts.load_json(study_arg(args, "--config"))
  let collection = @artifacts.load_json(study_arg(args, "--collection"))
  let teacher_path = study_arg(args, "--teacher")
  let teacher = @artifacts.load_json(teacher_path)
  guard study_text(teacher, "provider_sha256") ==
    @artifacts.sha256(@fs.read_file(provider_source).binary()) else {
    fail("teacher implementation differs from fitted source")
  }
  let output = study_arg(args, "--output")
  if !@fs.exists(output) {
    @fs.mkdir(output, recursive=true)
  }
  let runtime = @native_physics.Runtime::open(library, scene)
  let dt = study_num(collection, "control_dt_s")
  let parameters = @balance_native.parameters_from_json(
    study_field(teacher, "parameters"),
  )
  if command == "collect-teacher" {
    let episodes : Array[@native_physics.Episode] = []
    let trials : Array[@native_physics.Trial] = []
    let seeds : Array[Int32] = @json.from_json(
      study_field(config, "teacher_seeds"),
    )
    for raw in study_cases(collection, true) {
      let case : @native_physics.Case = @json.from_json(raw)
      for seed in seeds {
        let feedback = @balance_native.NativeBalanceTeacher::new(
          runtime, parameters, dt,
        )
        let rng = @numeric.Rng::new(seed.to_uint())
        let (offset, schedule) = @balance_native.sample_reference(
          runtime, raw, seed,
        )
        let (episode, trial) = runtime.rollout(
          case,
          seed,
          "policy",
          study_num(collection, "duration_s"),
          dt,
          fn() { rng.normal() },
          policy=fn(obs, goal) { try! feedback.predict(obs, goal) },
          offset?,
          schedule?,
          fall_height=study_num(collection, "fall_height_m"),
          fall_upright=study_num(collection, "fall_upright_z"),
        )
        let id = episode.id + "-temporal-teacher"
        episodes.push({ ..episode, id, })
        trials.push({ ..trial, episode_id: id, })
      }
    }
    let dataset = study_dataset(runtime, episodes, collection)
    ignore(@artifacts.save_json(output + "/dataset.json", dataset))
    let report : Json = {
      "format": "moonrobo.g1-temporal-teacher.v1",
      "episodes": episodes.length().to_json(),
      "transitions": episodes
      .fold(init=0, fn(n, e) { n + e.steps.length() })
      .to_json(),
      "falls": trials.filter(fn(t) { t.failed }).length().to_json(),
      "trials": trials.to_json(),
      "collection": collection,
      "teacher_sha256": @artifacts.sha256(@fs.read_file(teacher_path).binary()).to_json(),
      "source_language": "moonbit",
      "physical_execution_allowed": false,
    }
    ignore(@artifacts.save_json(output + "/report.json", report))
    println(report.stringify())
    return
  }
  let experiment = @artifacts.load_json(study_arg(args, "--experiment"))
  let test_seeds : Array[Int32] = @json.from_json(
    study_field(config, "test_seeds"),
  )
  if command == "evaluate" {
    let actor = @temporal.load_temporal(study_arg(args, "--checkpoint"))
    let report = study_evaluate(runtime, actor, experiment, test_seeds, None)
    ignore(@artifacts.save_json(output + "/physics.json", report))
    println(study_field(report, "summary").stringify())
    return
  }
  guard command == "fit" else { fail("unsupported temporal training command") }
  let h = study_int(config, "history_length")
  let f = study_int(config, "future_length")
  let data_path = study_arg(args, "--data")
  let original = study_points(
    runtime,
    @artifacts.load_json(data_path),
    collection,
    h,
    f,
  )
  let validation : Array[Int32] = @json.from_json(
    study_field(config, "validation_seeds"),
  )
  let seeds : Array[Int32] = @json.from_json(study_field(config, "seeds"))
  let runs : Array[Json] = []
  for seed in seeds {
    let incoming = study_checkpoint(
      study_arg(args, "--policies"),
      "actor",
      seed,
    )
    let checkpoint = @training.load_learning_checkpoint(incoming, "g1-actor")
    let base = @training.actor_from_checkpoint(checkpoint)
    let actor = @temporal.TemporalPolicy::new(
      base,
      h,
      f,
      study_int(config, "adapter_width"),
      @numeric.Rng::new(seed.to_uint()),
    )
    // Zero final adapter must preserve each actual action. This is checked on
    // every original point before any collection or optimizer step.
    for point in original {
      guard actor.predict(point.history, point.goal, point.future) ==
        base.predict(point.history[point.history.length() - 1], point.goal) else {
        fail("zero adapter changed parent action")
      }
    }
    let optimizer = @numeric.Adam::new(
      actor.parameters().length(),
      study_num(config, "actor_learning_rate"),
    )
    let rng = @numeric.Rng::new(
      (study_int(config, "sampling_seed") + seed).to_uint(),
    )
    let first = study_evaluate(
      runtime,
      actor,
      experiment,
      validation,
      Some("validation"),
    )
    let base_validation = study_base_evaluate(
      runtime,
      Some(base),
      experiment,
      validation,
      Some("validation"),
    )
    guard study_field(first, "trials") == study_field(base_validation, "trials") else {
      fail("zero temporal adapter changed parent closed-loop trace")
    }
    let mut best = first
    let mut selected = 0
    let mut best_weights = actor.parameters()
    let history : Array[Json] = [
      { "round": 0, "validation": study_field(best, "summary") },
    ]
    let recent : Array[@temporal.TemporalPoint] = []
    let logs : Array[Json] = []
    let capacity = study_int(config, "recent_points")
    let batch_size = study_int(config, "batch_size")
    guard batch_size > 0 &&
      capacity > 0 &&
      study_int(config, "rounds") >= 0 &&
      study_int(config, "updates_per_round") > 0 else {
      fail("invalid temporal batch/recent/update budget")
    }
    let started = @async.now()
    for round in 0..<study_int(config, "rounds") {
      let reset = study_int(config, "collection_seed_base") +
        seed * 10000 +
        2 * round
      let actor_digest = @artifacts.sha256(
        @artifacts.encode_npy([actor.parameters().length()], actor.parameters()),
      )
      let episodes : Array[@native_physics.Episode] = []
      let targets : Array[Array[Array[Double]]] = []
      let trials : Array[@native_physics.Trial] = []
      for raw in study_cases(collection, true) {
        let case : @native_physics.Case = @json.from_json(raw)
        for reset_seed in [reset, reset + 1] {
          let (offset, schedule) = @balance_native.sample_reference(
            runtime, raw, reset_seed,
          )
          let labeled = collect_labeled(
            runtime,
            actor,
            [{ case, offset, schedule, }],
            [reset_seed],
            0U,
            0.0,
            study_num(collection, "duration_s"),
            dt,
            Some(parameters),
            fall_height=study_num(collection, "fall_height_m"),
            fall_upright=study_num(collection, "fall_upright_z"),
          )
          let suffix = "-temporal-" +
            study_text(config, "method") +
            "-\{round}-" +
            actor_digest[:16].to_owned()
          episodes.append(
            labeled.episodes.map(fn(e) { { ..e, id: e.id + suffix, } }),
          )
          targets.append(labeled.teacher_targets)
          trials.append(
            labeled.trials.map(fn(t) {
              { ..t, episode_id: t.episode_id + suffix, }
            }),
          )
          recent.append(labeled.points)
        }
      }
      while recent.length() > capacity {
        ignore(recent.remove(0))
      }
      guard !recent.is_empty() else {
        fail("no newly labeled temporal samples")
      }
      logs.push({
        "round": (round + 1).to_json(),
        "actor_sha256": actor_digest.to_json(),
        "dataset": study_dataset(runtime, episodes, collection),
        "teacher_action_targets": targets.to_json(),
        "target_order": "one list per episode, one action per step; actual applied_action remains student control",
        "maximum_input_alignment_error": 0,
      })
      let mut loss = 0.0
      for _ in 0..<study_int(config, "updates_per_round") {
        let batch = Array::makei(batch_size, fn(i) {
          if i < batch_size / 2 {
            original[rng.index(original.length())]
          } else {
            recent[rng.index(recent.length())]
          }
        })
        loss = actor.clone_update(optimizer, batch)
        guard @numeric.finite(loss) else {
          fail("nonfinite temporal supervision loss")
        }
      }
      let current = study_evaluate(
        runtime,
        actor,
        experiment,
        validation,
        Some("validation"),
      )
      history.push({
        "round": (round + 1).to_json(),
        "validation": study_field(current, "summary"),
        "action_loss": loss.to_json(),
        "episodes": episodes.length().to_json(),
        "transitions": episodes
        .fold(init=0, fn(n, e) { n + e.steps.length() })
        .to_json(),
        "falls": trials.filter(fn(t) { t.failed }).length().to_json(),
        "maximum_input_alignment_error": 0,
      })
      if study_better(current, best) {
        best = current
        selected = round + 1
        best_weights = actor.parameters()
      }
    }
    let training_seconds = (@async.now() - started).to_double() / 1000
    let log_path = output + "/student-physics-seed-\{seed}.jsonl.gz"
    let log_sha = @artifacts.save_jsonl(log_path, logs)
    let evidence : Json = {
      "incoming_checkpoint": incoming.to_json(),
      "incoming_sha256": @artifacts.sha256(@fs.read_file(incoming).binary()).to_json(),
      "teacher_sha256": @artifacts.sha256(@fs.read_file(teacher_path).binary()).to_json(),
      "student_physics_sha256": log_sha.to_json(),
      "config": config,
      "source_language": "moonbit",
    }
    let latest = "latest-actor-seed-\{seed}.moon.json"
    let name = "actor-seed-\{seed}.moon.json"
    ignore(
      @temporal.save_temporal(
        output + "/" + latest,
        actor,
        temporal_metadata(
          checkpoint.metadata,
          config,
          actor,
          study_int(config, "rounds") * study_int(config, "updates_per_round"),
          evidence,
        ),
      ),
    )
    actor.restore(best_weights)
    ignore(
      @temporal.save_temporal(
        output + "/" + name,
        actor,
        temporal_metadata(
          checkpoint.metadata,
          config,
          actor,
          selected * study_int(config, "updates_per_round"),
          evidence,
        ),
      ),
    )
    let restored = @temporal.load_temporal(output + "/" + name)
    guard restored.parameters() == actor.parameters() else {
      fail("temporal checkpoint reload differs")
    }
    let candidate = study_evaluate(
      runtime,
      restored,
      experiment,
      test_seeds,
      None,
    )
    let baseline = study_base_evaluate(
      runtime,
      None,
      experiment,
      test_seeds,
      None,
    )
    ignore(
      @artifacts.save_json(output + "/physics-seed-\{seed}.json", {
        "baseline": baseline,
        "candidate": candidate,
      }),
    )
    runs.push({
      "seed": seed.to_json(),
      "selected_round": selected.to_json(),
      "selected_update": (selected * study_int(config, "updates_per_round")).to_json(),
      "training_seconds": training_seconds.to_json(),
      "initial_matches_legacy": true,
      "history": history.to_json(),
      "checkpoint": name.to_json(),
      "latest_checkpoint": latest.to_json(),
      "candidate": study_field(candidate, "summary"),
      "qualifies": study_qualifies(
        study_field(candidate, "summary"),
        config,
        study_num(experiment, "duration_s"),
      ).to_json(),
      "student_physics": {
        "file": "student-physics-seed-\{seed}.jsonl.gz",
        "sha256": log_sha.to_json(),
      },
      "reload_matches": true,
    })
  }
  let provider = "src/learning_temporal/physics/study.mbt"
  let report : Json = {
    "format": "moonrobo.g1-temporal-fit.v1",
    "config": config,
    "runs": runs.to_json(),
    "checkpoint_selection": "validation-physics-only",
    "training_kind": "teacher-supervision-and-student-state-labeling",
    "data_sha256": @artifacts.sha256(@fs.read_file(data_path).binary()).to_json(),
    "provider_sha256": @artifacts.sha256(@fs.read_file(provider).binary()).to_json(),
    "provider_source": provider.to_json(),
    "source_language": "moonbit",
    "physical_execution_allowed": false,
    "any_qualified": runs
    .any(fn(row) { try! @json.from_json(study_field(row, "qualifies")) })
    .to_json(),
    "numerical_parity_verified": false,
  }
  ignore(@artifacts.save_json(output + "/report.json", report))
  println(report.stringify())
}
