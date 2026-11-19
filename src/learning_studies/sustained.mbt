///|
/// Fresh train-only sustained-teacher collection, two OLS representations, variant selection before final audits.
pub async fn run_sustained(
  library : String,
  scene : String,
  config_path : String,
  original_study : String,
  teacher_study : String,
  output : String,
) -> Unit {
  let config = @artifacts.load_json(config_path)
  let collection = @artifacts.load_json(original_study + "/collection.json")
  let experiment = @artifacts.load_json(original_study + "/experiment.json")
  let charter = @artifacts.load_json(original_study + "/charter.json")
  let teacher = @artifacts.load_json(teacher_study + "/teacher.json")
  let teacher_sha = @artifacts.sha256(
    @fs.read_file(teacher_study + "/teacher.json").binary(),
  )
  guard text(teacher, "provider_sha256") ==
    @artifacts.sha256(@fs.read_file(teacher_provider_source(teacher)).binary()) else {
    fail("sustained teacher fitted source changed")
  }
  guard text(teacher, "parameter_search_sha256") ==
    @artifacts.sha256(
      @fs.read_file(teacher_study + "/parameter-search.json").binary(),
    ) else {
    fail("train-selected teacher parameters changed")
  }
  let parameters = @balance_native.parameters_from_json(
    field(teacher, "parameters"),
  )
  let runtime = @native_physics.Runtime::open(library, scene)
  let geometry = @balance_native.make_spec(runtime)
  let dt = number(collection, "control_dt_s")
  let revision = text(collection, "source_revision")
  let training_resets : Array[Int32] = @json.from_json(
    field(config, "training_reset_seeds"),
  )
  let seeds : Array[Int32] = @json.from_json(field(config, "seeds"))
  let variants = array(config, "variants")
  guard !variants.is_empty() && !seeds.is_empty() else {
    fail("empty sustained variants/parents")
  }
  if !@fs.exists(output) {
    @fs.mkdir(output)
  }
  if !@fs.exists(output + "/policy") {
    @fs.mkdir(output + "/policy")
  }
  ignore(@artifacts.save_json(output + "/config.json", config))
  ignore(@artifacts.save_json(output + "/collection.json", collection))
  ignore(@artifacts.save_json(output + "/experiment.json", experiment))
  ignore(
    @artifacts.save_json(output + "/charter.json", {
      "config": config,
      "original_balance_study": original_study.to_json(),
      "incoming_policies": field(charter, "incoming_policies"),
      "teacher_study": teacher_study.to_json(),
    }),
  )
  let report_sources = @report_contract.capture(output, [
    (
      "teacher_implementation_sha256", "src/learning_balance/physics/teacher.mbt",
    ),
    ("teacher_algorithm_sha256", "src/learning_balance/teacher.mbt"),
    ("provider_sha256", "src/learning_studies/sustained.mbt"),
    ("head_provider_sha256", "src/learning_balance/heads.mbt"),
    ("feature_provider_sha256", "src/learning_balance/history.mbt"),
    ("teacher_provider_sha256", teacher_provider_source(teacher)),
  ])
  let start_time = @async.now()
  let observations : Array[Array[Double]] = []
  let goals : Array[Array[Double]] = []
  let targets : Array[Array[Double]] = []
  let features : Array[Array[Double]] = []
  let sources : Array[Json] = []
  let training_trials : Array[Json] = []
  let training_log : Array[Json] = []
  for case_json in array(collection, "cases") {
    guard text(case_json, "split") == "train" else {
      fail("sustained fitting accepts train cases only")
    }
    for reset in training_resets {
      let (episode, trial) = teacher_rollout(
        runtime, case_json, reset, config, dt, parameters,
      )
      let id = episode.id + "-sustained-teacher-training"
      let episode = { ..episode, id, }
      match trial {
        Object(fields) => fields["episode_id"] = id.to_json()
        _ => ()
      }
      let obs = episode.steps.map(s => s.observation)
      observations.append(obs)
      goals.append(episode.steps.map(s => s.goal))
      targets.append(episode.steps.map(s => s.applied_action))
      features.append(
        @balance.sequence_features(
          geometry,
          obs,
          dt,
          None,
          @balance.GravityGyro,
        ),
      )
      sources.push({
        "episode_id": id.to_json(),
        "case_id": text(case_json, "id").to_json(),
        "source_family": field(case_json, "family"),
        "split": "train",
        "seed": reset.to_json(),
        "points": obs.length().to_json(),
      })
      training_trials.push(trial)
      training_log.push(
        episode_record(runtime, revision, dt, episode, trial, {
          "role": "teacher-training",
        }),
      )
    }
  }
  guard !observations.is_empty() else {
    fail("empty sustained training corpus")
  }
  let training_summary = @balance.summarize_recorded_trials(training_trials)
  let training_sha = @artifacts.save_jsonl(
    output + "/teacher-training.jsonl.gz",
    training_log,
  )
  let sources_sha = @artifacts.save_json(
    output + "/training-sources.json",
    sources.to_json(),
  )
  let collection_seconds = (@async.now() - start_time).to_double() / 1000
  let fit_start = @async.now()
  let (lower, upper) = runtime.control_bounds()
  let fitted : Map[String, @balance.SustainedBalanceHead] = Map([])
  let fits : Array[Json] = []
  for representation in ["range", "pose_rate"] {
    let head = @balance.SustainedBalanceHead::new(
      runtime.joint_names(),
      lower,
      upper,
      pose_rate=representation == "pose_rate",
      fit_bound=parameters.residual_bound,
    )
    let (ankle_fit, waist_fit) = head.fit(
      observations,
      goals,
      targets,
      features,
      margin=number(config, "uncensored_margin_rad"),
    )
    fitted[representation] = head
    fits.push({
      "representation": representation.to_json(),
      "ankle_fit": ankle_fit.to_json(),
      "waist_fit": waist_fit.to_json(),
    })
  }
  let fit_seconds = (@async.now() - fit_start).to_double() / 1000
  let checkpoints : Map[(Int32, String), Json] = Map([])
  let states : Map[Int32, Array[Double]] = Map([])
  for seed in seeds {
    let incoming = policy_path(
      text(charter, "incoming_policies") + "/actor-seed-" + seed.to_string(),
    )
    let parent = @temporal.load_temporal(incoming)
    states[seed] = parent.parameters()
    for variant in variants {
      let base = fitted[text(variant, "representation")]
      let control_waist : Bool = @json.from_json(
        field(variant, "control_waist"),
      )
      let head = {
        ..base,
        control_waist,
        output_bound: number(variant, "output_bound"),
      }
      let policy : @balance_policy.BalancePolicy = {
        parent,
        head: @balance.Sustained(head),
        geometry,
        dt,
        window: None,
      }
      let path = output +
        "/policy/actor-" +
        text(variant, "name") +
        "-seed-" +
        seed.to_string() +
        ".moon.json"
      let sha = @balance_policy.save(path, policy, {
        "parent_sha256": @artifacts.sha256(@fs.read_file(incoming).binary()).to_json(),
        "teacher_sha256": teacher_sha.to_json(),
        "training_sha256": training_sha.to_json(),
        "training_points": observations.length().to_json(),
        "fit": "two shared deterministic ankle/waist fits; parent seeds are not independent head fits",
      })
      let restored = @balance_policy.load(path, sustained=true)
      guard restored.parent.parameters() == states[seed] &&
        restored.head.to_json() == policy.head.to_json() else {
        fail(
          "sustained bundle round-trip changed head or embedded frozen parent",
        )
      }
      checkpoints[(seed, text(variant, "name"))] = {
        "path": path.to_json(),
        "sha256": sha.to_json(),
        "head_state_sha256": @artifacts.sha256(
          @utf8.encode(head.to_json().stringify()),
        ).to_json(),
      }
    }
  }
  let selection : Array[Json] = []
  let selection_log : Array[Json] = []
  for variant in variants {
    for seed in seeds {
      let cp = checkpoints[(seed, text(variant, "name"))]
      let policy = @balance_policy.load(text(cp, "path"), sustained=true)
      let trials : Array[Json] = []
      let alignment : Array[Json] = []
      for case_json in array(collection, "cases") {
        let (episode, trial, checked) = sustained_rollout(
          runtime,
          policy,
          case_json,
          integer(config, "selection_seed_base") + 10000 * seed,
          config,
          "-sustained-" +
          seed.to_string() +
          "-" +
          text(variant, "name") +
          "-selection",
        )
        trials.push(trial)
        alignment.push(checked)
        selection_log.push(
          episode_record(runtime, revision, dt, episode, trial, {
            "role": "training-selection",
            "seed": seed.to_json(),
            "variant": field(variant, "name"),
            "alignment": checked,
          }),
        )
      }
      guard policy.parent.parameters() == states[seed] else {
        fail("selection changed frozen parent")
      }
      selection.push({
        "seed": seed.to_json(),
        "variant": field(variant, "name"),
        "summary": @balance.summarize_recorded_trials(trials),
        "trials": trials.to_json(),
        "alignment": alignment.to_json(),
        "checkpoint": cp,
      })
    }
  }
  let selection_sha = @artifacts.save_jsonl(
    output + "/selection-physics.jsonl.gz",
    selection_log,
  )
  let selections : Array[Json] = []
  let mut chosen : Json? = None
  for variant in variants {
    let trials = []
    for row in selection {
      if text(row, "variant") == text(variant, "name") {
        trials.append(array(row, "trials"))
      }
    }
    let summary = @balance.summarize_recorded_trials(trials)
    let control_waist : Bool = @json.from_json(field(variant, "control_waist"))
    let coefficients = (if text(variant, "representation") == "pose_rate" {
        24
      } else {
        16
      }) +
      (if control_waist { 3 } else { 0 })
    let result = match variant {
      Object(fields) => Json::object(fields.copy())
      _ => variant
    }
    match result {
      Object(fields) => {
        fields["summary"] = summary
        fields["active_coefficients"] = coefficients.to_json()
      }
      _ => ()
    }
    selections.push(result)
    if (match chosen {
        None => true
        Some(best) =>
          selection_better(
            summary,
            coefficients,
            field(best, "summary"),
            integer(best, "active_coefficients"),
          )
      }) {
      chosen = Some(result)
    }
  }
  let chosen = chosen.unwrap()
  // Selection is committed before any canonical/final-audit rollout starts.
  let selected_sha = @artifacts.save_json(output + "/selected.json", {
    "selected_variant": chosen,
    "selection": selections.to_json(),
    "scope": "training-family selection only; no canonical or final audit evaluation has run",
  })
  let final_rows : Array[Json] = []
  let final_log : Array[Json] = []
  let canonical_resets : Array[Int32] = @json.from_json(
    field(config, "canonical_reset_seeds"),
  )
  for seed in seeds {
    let cp = checkpoints[(seed, text(chosen, "name"))]
    let policy = @balance_policy.load(text(cp, "path"), sustained=true)
    let conditions = [
      ("canonical-development", array(experiment, "cases"), canonical_resets),
      (
        "training-family-audit",
        array(collection, "cases"),
        [integer(config, "audit_seed_base") + 10000 * seed],
      ),
    ]
    for (scope, cases, resets) in conditions {
      let trials : Array[Json] = []
      let alignment : Array[Json] = []
      for case_json in cases {
        for reset in resets {
          let (episode, trial, checked) = sustained_rollout(
            runtime,
            policy,
            case_json,
            reset,
            config,
            "-sustained-" +
            seed.to_string() +
            "-" +
            text(chosen, "name") +
            "-" +
            scope,
          )
          trials.push(trial)
          alignment.push(checked)
          final_log.push(
            episode_record(runtime, revision, dt, episode, trial, {
              "role": "selected-final",
              "seed": seed.to_json(),
              "scope": scope.to_json(),
              "variant": field(chosen, "name"),
              "alignment": checked,
            }),
          )
        }
      }
      final_rows.push({
        "role": "selected-final",
        "seed": seed.to_json(),
        "scope": scope.to_json(),
        "summary": @balance.summarize_recorded_trials(trials),
        "trials": trials.to_json(),
        "alignment": alignment.to_json(),
        "checkpoint": cp,
      })
    }
    guard policy.parent.parameters() == states[seed] else {
      fail("final evaluation changed frozen parent")
    }
  }
  let teacher_conditions : Array[(String, Array[Json], Array[Int32])] = [
    ("canonical-development", array(experiment, "cases"), canonical_resets),
  ]
  for seed in seeds {
    teacher_conditions.push(
      (
        "training-family-audit",
        array(collection, "cases"),
        [integer(config, "audit_seed_base") + 10000 * seed],
      ),
    )
  }
  for (scope, cases, resets) in teacher_conditions {
    let trials = []
    for case_json in cases {
      for reset in resets {
        let (episode, trial) = teacher_rollout(
          runtime, case_json, reset, config, dt, parameters,
        )
        let episode = {
          ..episode,
          id: episode.id + "-sustained-teacher-reference-" + scope,
        }
        match trial {
          Object(fields) => fields["episode_id"] = episode.id.to_json()
          _ => ()
        }
        trials.push(trial)
        final_log.push(
          episode_record(runtime, revision, dt, episode, trial, {
            "role": "teacher-reference",
            "scope": scope.to_json(),
            "seed": (None : Int32?).to_json(),
          }),
        )
      }
    }
    final_rows.push({
      "role": "teacher-reference",
      "seed": (None : Int32?).to_json(),
      "scope": scope.to_json(),
      "reset_seeds": resets.to_json(),
      "summary": @balance.summarize_recorded_trials(trials),
      "trials": trials.to_json(),
    })
  }
  let pooled : Array[Json] = []
  for role in ["selected-final", "teacher-reference"] {
    for scope in ["canonical-development", "training-family-audit"] {
      let trials = []
      for row in final_rows {
        if text(row, "role") == role && text(row, "scope") == scope {
          trials.append(array(row, "trials"))
        }
      }
      let summary = @balance.summarize_recorded_trials(trials)
      pooled.push(
        @report_contract.pooled(trials, {
          "role": role.to_json(),
          "scope": scope.to_json(),
          "numeric_pass": (integer(summary, "falls") == 0 &&
          number(summary, "mean_joint_rmse_rad") <=
          number(config, "max_mean_joint_rmse_rad")).to_json(),
        }),
      )
    }
  }
  let evaluation_sha = @artifacts.save_jsonl(
    output + "/evaluation-physics.jsonl.gz",
    final_log,
  )
  ignore(
    @artifacts.save_json(
      output + "/report.json",
      @report_contract.attach(
        {
          "format": "moonrobo.moonbit-sustained-balance-study.v1",
          "config": config,
          "training_episodes": sources.length().to_json(),
          "training_points": observations.length().to_json(),
          "training_summary": training_summary,
          "collection_seconds": collection_seconds.to_json(),
          "fit_seconds": fit_seconds.to_json(),
          "fits": fits.to_json(),
          "selection": selection.to_json(),
          "selection_variants": selections.to_json(),
          "selected_variant": chosen,
          "final": final_rows.to_json(),
          "pooled": pooled.to_json(),
          "training_sha256": training_sha.to_json(),
          "training_sources_sha256": sources_sha.to_json(),
          "selection_sha256": selection_sha.to_json(),
          "evaluation_sha256": evaluation_sha.to_json(),
          "selected_sha256": selected_sha.to_json(),
          "teacher_sha256": teacher_sha.to_json(),
          "shared_representation_fits": 2,
          "parent_actors": seeds.length().to_json(),
          "wall_seconds": ((@async.now() - start_time).to_double() / 1000).to_json(),
          "release_qualified": false,
          "physical_execution_allowed": false,
          "parity_status": "awaiting-python-comparison",
        },
        report_sources,
      ),
    ),
  )
}
