///|
/// Deterministic relabel/refit gate precedes all registry success artifacts.
/// Only genuine recorded-state forwarding is used; no simulator steps are taken.
pub async fn export_learned(
  study : String,
  long_study : String,
  library : String,
  scene : String,
  output : String,
  teacher_provider_source~ : String = "",
  provider_source~ : String = "src/learning_registry/learned/export.mbt",
) -> Json {
  let fit = @artifacts.load_json(study + "/report.json")
  let long_report = @artifacts.load_json(long_study + "/report.json")
  let fit_sha = digest(study + "/report.json")
  let long_sha = digest(long_study + "/report.json")
  guard text(long_report, "fit_report_sha256") == fit_sha else {
    fail("long evaluation belongs to another fitted study")
  }
  let config = @artifacts.load_json(study + "/config.json")
  let collection = @artifacts.load_json(study + "/collection.json")
  let experiment = @artifacts.load_json(study + "/experiment.json")
  let teacher = @artifacts.load_json(study + "/teacher.json")
  let charter = @artifacts.load_json(study + "/charter.json")
  let teacher_provider_source = teacher_source(
    teacher, charter, teacher_provider_source,
  )
  let teacher_source_sha = digest(teacher_provider_source)
  guard text(teacher, "provider_sha256") == teacher_source_sha else {
    fail("teacher relabeling source changed")
  }
  let intervention = text(charter, "source_intervention") +
    "/intervention-physics.jsonl.gz"
  let records = @artifacts.load_jsonl(
    intervention,
    expected_sha256=text(fit, "source_sha256"),
  )
  let runtime = @sim.Runtime::open(library, scene)
  let dt = number(collection, "control_dt_s")
  ignore(runtime.control_substeps(dt))
  let geometry = @balance_native.make_spec(runtime)
  let points = @studies.train_points(
    runtime,
    geometry,
    records,
    config,
    collection,
    @balance_native.parameters_from_json(field(teacher, "parameters")),
  )
  guard points.sources.to_json() ==
    @artifacts.load_json(study + "/training-sources.json") else {
    fail("exported training manifest differs from the actual fit")
  }
  let windows : Array[Int32?] = @json.from_json(field(config, "windows"))
  guard windows == [Some(10), None] else {
    fail(
      "learned registry export requires h10 and full windows in fitted order",
    )
  }
  let seeds : Array[Int32] = @json.from_json(field(config, "seeds"))
  guard seeds.length() == 3 &&
    seeds[0] != seeds[1] &&
    seeds[0] != seeds[2] &&
    seeds[1] != seeds[2] else {
    fail("learned export requires three distinct frozen parent seeds")
  }
  let (lower, upper) = runtime.control_bounds()
  let checkpoints : Map[(String, Int32), String] = Map([])
  let mut verified_heads = 0
  for (mode, window) in [("h10", Some(10)), ("full", None)] {
    guard points.features.get(mode) is Some(features) &&
      features.length() == points.observations.length() else {
      fail("missing complete observer feature window")
    }
    let fitted = @balance.LearnedAnkleHead::new(
      runtime.joint_names(),
      lower,
      upper,
      bound=number(config, "residual_bound_rad"),
    )
    ignore(
      fitted.fit(
        Array::makei(points.observations.length(), i => {
          fitted.inputs(points.observations[i], features[i])
        }),
        points.goals,
        points.targets,
        margin=number(config, "uncensored_margin_rad"),
      ),
    )
    for seed in seeds {
      let path = checkpoint_path(study, mode, seed)
      let saved = @balance_policy.load(path)
      guard saved.window == window && saved.dt == dt else {
        fail("saved head observer window/cadence differs")
      }
      guard saved.head is @balance.Learned(head) else {
        fail("learned v1 ankle head is required")
      }
      assert_exact_head(fitted, head)
      checkpoints[(mode, seed)] = path
      verified_heads += 1
    }
  }
  guard verified_heads == 6 else {
    fail("all six exact fitted heads must be verified before exporting labels")
  }
  let common = output + "/common"
  guard provider_source.has_suffix(".mbt") else {
    fail("native exporter provenance must name its actual MoonBit source")
  }
  @fs.mkdir(output + "/provider-sources", recursive=true)
  @fs.write_file(
    output + "/provider-sources/learned_balance_export.mbt",
    @fs.read_file(provider_source).binary(),
    create_mode=CreateOrTruncate,
  )
  @fs.mkdir(common, recursive=true)
  let selected : Map[String, Bool] = Map([])
  for row in points.sources {
    selected[text(row, "episode_id")] = true
  }
  let written : Map[String, Bool] = Map([])
  let chunks : Array[Json] = []
  let mut offset = 0
  let mut representative_sha = ""
  for record in records {
    let dataset = field(record, "dataset")
    let episodes : Array[Json] = []
    for episode in array(dataset, "episodes") {
      if selected.contains(text(episode, "id")) {
        episodes.push(episode)
      }
    }
    if episodes.is_empty() {
      continue
    }
    let targets : Array[Array[Array[Double]]] = []
    for episode in episodes {
      let id = text(episode, "id")
      guard !written.contains(id) else {
        fail("training episode is repeated in registry archive")
      }
      written[id] = true
      let count = array(episode, "steps").length()
      guard offset <= points.targets.length() - count else {
        fail("training label offsets exceed fitted source rows")
      }
      targets.push(points.targets[offset:offset + count].to_owned())
      offset += count
    }
    let dataset = replace(dataset, { "episodes": episodes.to_json() })
    if chunks.is_empty() {
      representative_sha = @artifacts.save_json(
        common + "/dataset.json.gz",
        dataset,
      )
    }
    chunks.push({
      "source_parent_seed": field(record, "seed"),
      "source_mode": field(record, "mode"),
      "dataset": dataset,
      "teacher_action_targets": targets.to_json(),
      "target_dtype": "float64 native labels; exact saved-head equality required before materialization",
      "role": "train-only",
    })
  }
  guard offset == points.targets.length() &&
    chunks.length() == 6 &&
    written.length() == selected.length() else {
    fail("incomplete six-chunk training archive")
  }
  let training_sha = @artifacts.save_jsonl(
    common + "/balance-training.jsonl.gz",
    chunks,
  )
  let metadata : Json = {
    "training_episodes": points.sources.length().to_json(),
    "training_points": points.targets.length().to_json(),
    "training_chunks": chunks.length().to_json(),
    "training_sha256": training_sha.to_json(),
    "representative_sha256": representative_sha.to_json(),
    "exact_refit_matches_all_six_heads": true,
    "fit_report_sha256": fit_sha.to_json(),
    "long_report_sha256": long_sha.to_json(),
    "provider_sha256": digest(provider_source).to_json(),
    "provider_source": provider_source.to_json(),
    "provider_snapshot": "provider-sources/learned_balance_export.mbt",
    "source_language": "moonbit",
    "teacher_provider_source": teacher_provider_source.to_json(),
    "teacher_provider_sha256": teacher_source_sha.to_json(),
    "native_teacher_wrapper_sha256": digest(
      "src/learning_balance/physics/teacher.mbt",
    ).to_json(),
    "native_teacher_kernel_sha256": digest("src/learning_balance/teacher.mbt").to_json(),
    "relabel_numeric_backend": "native-f64; legacy Float32 and OLS differences fail exact reproduction",
  }
  for
    (scope, folder, report, short) in [
      ("ten-second", study, fit, true),
      ("thirty-second", long_study, long_report, false),
    ] {
    let evaluations = read_evaluations(runtime, folder, report, short, dt)
    for mode in ["h10", "full"] {
      let destination = output + "/" + scope + "-" + mode + "/policy"
      @fs.mkdir(destination, recursive=true)
      let runs : Array[Json] = []
      for seed in seeds {
        guard evaluations.get((seed, "student")) is Some(baseline) &&
          evaluations.get((seed, mode)) is Some(candidate) else {
          fail("missing paired learned evaluation cell")
        }
        ignore(
          @artifacts.save_json(
            destination + "/physics-seed-" + seed.to_string() + ".json",
            {
              "baseline": baseline,
              "candidate": candidate,
              "scope": (scope + "-development").to_json(),
              "physical_execution_allowed": false,
            },
          ),
        )
        let checkpoint = checkpoints[(mode, seed)]
        let name = basename(checkpoint)
        let qualifies = integer(field(candidate, "summary"), "falls") == 0 &&
          number(field(candidate, "summary"), "mean_joint_rmse_rad") <=
          number(config, "max_mean_joint_rmse_rad")
        runs.push({
          "seed": seed.to_json(),
          "selected_update": 1,
          "checkpoint": name.to_json(),
          "latest_checkpoint": name.to_json(),
          "baseline": field(baseline, "summary"),
          "candidate": field(candidate, "summary"),
          "qualifies": qualifies.to_json(),
          "checkpoint_sha256": digest(checkpoint).to_json(),
        })
      }
      let duration = if short { 10 } else { 30 }
      let policy : Json = {
        "format": "moonrobo.g1-learned-balance-fit.v1",
        "runs": runs.to_json(),
        "experiment": replace(experiment, { "duration_s": duration.to_json() }),
        "mode": mode.to_json(),
        "window": (if mode == "h10" { Some(10) } else { None }).to_json(),
        "seed_semantics": "frozen parent training seed; one shared deterministic fitted ankle head per arm",
        "head_fit_count": 1,
        "selected_update_semantics": "one closed-form fit; no optimizer/checkpoint selection",
        "source_training": metadata,
        "checkpoint_format": "moonrobo.g1-learned-balance-actor.v1",
        "qualification_scope": (scope +
        "-development: zero falls and mean joint RMSE <= 0.15 rad").to_json(),
        "collection_role": "representative first train chunk; complete train data and separate labels in balance-training.jsonl.gz",
        "evaluation_role": "complete recorded evaluation, including independent train-family audit for ten-second study",
        "evaluation_log_sha256": field(report, "evaluation_log_sha256"),
        "release_qualified": false,
        "physical_execution_allowed": false,
      }
      ignore(@artifacts.save_json(destination + "/report.json", policy))
    }
    ignore(
      @artifacts.save_json(common + "/" + scope + "-study.json", {
        "fit": fit,
        "evaluation": report,
        "export": metadata,
      }),
    )
  }
  ignore(@artifacts.save_json(output + "/export.json", metadata))
  metadata
}
