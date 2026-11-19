///|
fn[T] need(result : Result[T, @store.MoonDataStoreIssue]) -> T raise {
  match result {
    Ok(value) => value
    Err(error) => fail(error.code + ": " + error.message)
  }
}

///|
fn valid_id(id : String) -> Bool {
  !id.is_empty() &&
  id
  .iter()
  .all(c => {
    c.is_ascii_alphabetic() || c.is_ascii_digit() || c == '-' || c == '_'
  })
}

///|
fn source_id(id : String) -> String {
  "learning-" + id
}

///|
fn finite(value : Double) -> Bool {
  value == value && value - value == 0.0
}

///|
fn check_trial(trial : TrialSummary) -> Unit raise {
  guard trial.trials > 0 &&
    trial.falls >= 0 &&
    trial.falls <= trial.trials &&
    finite(trial.mean_survival_s) &&
    trial.mean_survival_s >= 0.0 &&
    finite(trial.mean_joint_rmse_rad) &&
    trial.mean_joint_rmse_rad >= 0.0 else {
    fail("invalid reported trial statistics")
  }
}

///|
fn checkpoint_path(folder : String, name : String) -> String raise {
  guard !name.is_empty() &&
    !name.contains("/") &&
    !name.contains("\\") &&
    name != "." &&
    name != ".." else {
    fail("checkpoint must be a local filename")
  }
  folder + "/" + name
}

///|
fn seal(
  root : String,
  run_dir : String,
  relative : String,
  kind : String,
) -> LearningPayload raise {
  let blob = need(
    @blob.put_local_file(
      root,
      run_dir + "/" + relative,
      kind~,
      content_type=if relative.has_suffix(".json") {
        "application/json"
      } else {
        "application/octet-stream"
      },
    ),
  )
  { relative_path: relative, data_ref: blob.data_ref, }
}

///|
fn read_experiment(root : String, id : String) -> LearningExperiment raise {
  guard valid_id(id) else { fail("invalid experiment id") }
  let source = need(@store.read_source(root, source_id(id)))
  guard source.kind == "learning-experiment" else {
    fail("not a learning experiment source")
  }
  for data_ref in source.source_refs {
    if data_ref.kind == "learning-summary" {
      let relative = @data.moondata_payload_uri_relative_path(data_ref.uri).unwrap_or_else(() => {
          fail("unsafe summary ref")
        },
      )
      let path = root + "/" + relative
      guard need(@blob.local_file_checksum(path)) == data_ref.checksum else {
        fail("learning summary checksum mismatch")
      }
      let summary : LearningExperiment = @json.from_json(
        @json.parse(@fsx.read_file_to_string(path)),
      )
      guard summary.format == "moonrobo.learning-experiment.v1" &&
        summary.experiment_id == id &&
        summary.source_id == source.source_id &&
        !summary.physical_execution_allowed else {
        fail("invalid learning summary binding")
      }
      return summary
    }
  }
  fail("learning source has no summary")
}

///|
/// Inspect immutable MoonData references without resolving the original run directory.
///
/// ```mbt nocheck
/// let experiment = @moondata_learning.inspect("book/moondata", "round-one").unwrap()
/// assert_false(experiment.physical_execution_allowed)
/// ```
pub fn inspect(
  root : String,
  id : String,
) -> Result[LearningExperiment, String] {
  try read_experiment(root, id) catch {
    error => Err(error.to_string())
  } noraise {
    value => Ok(value)
  }
}

///|
fn import_experiment(
  root : String,
  run_dir : String,
  id : String,
  now_ms : Int64,
) -> LearningExperiment raise {
  guard valid_id(id) else {
    fail("experiment id must contain only letters, digits, '-' or '_'")
  }
  if @fsx.path_exists(@store.source_path(root, source_id(id))) {
    let previous = read_experiment(root, id)
    for payload in previous.payloads {
      guard need(
          @blob.local_file_checksum(run_dir + "/" + payload.relative_path),
        ) ==
        payload.data_ref.checksum else {
        fail("experiment id already exists with different input bytes")
      }
    }
    ignore(need(@index.rebuild_catalog(root, now_ms)))
    return previous
  }
  // Method-aligned experiments retain their own metrics and have no fabricated
  // legacy baseline/candidate pair. The adapter seals their original reports.
  if @fsx.path_exists(run_dir + "/report.json") {
    let report = @json.parse(@fsx.read_file_to_string(run_dir + "/report.json"))
    if report is { "format": "moonrobo.supermimic-aligned-training.v1", .. } {
      return import_aligned_experiment(root, run_dir, id, now_ms, report)
    }
  }
  let policy : PolicyReport = @json.from_json(
    @json.parse(@fsx.read_file_to_string(run_dir + "/policy/report.json")),
  )
  let physics_ppo = policy.format == "moonrobo.g1-temporal-ppo-fit.v1"
  let disturbance = policy.format == "moonrobo.g1-temporal-disturbance-fit.v1"
  let balance = policy.format == "moonrobo.g1-learned-balance-fit.v1"
  let reference = policy.format == "moonrobo.g1-reference-policy-fit.v1"
  let reference_learning = policy.format ==
    "moonrobo.g1-reference-learning-fit.v1"
  let requires_dynamics = !physics_ppo &&
    !disturbance &&
    !balance &&
    !reference &&
    !reference_learning
  guard (
      policy.format == "moonrobo.g1-policy-fit.v1" ||
      physics_ppo ||
      disturbance ||
      balance ||
      reference ||
      reference_learning
    ) &&
    !policy.runs.is_empty() else {
    fail(
      "expected G1 model-based, temporal PPO, disturbance, balance or reference policy report",
    )
  }
  let dynamics_runs : Array[DynamicsRun] = if !requires_dynamics {
    []
  } else {
    let dynamics : DynamicsReport = @json.from_json(
      @json.parse(@fsx.read_file_to_string(run_dir + "/fit/report.json")),
    )
    guard dynamics.format == "moonrobo.dynamics-fit.v1" else {
      fail("expected G1 dynamics report")
    }
    dynamics.runs
  }
  let seeds : Array[Int32] = []
  for run in policy.runs {
    guard !seeds.contains(run.seed) && run.seed >= 0 && run.selected_update >= 0 else {
      fail("invalid or duplicate policy seed/update")
    }
    seeds.push(run.seed)
    check_trial(run.baseline)
    check_trial(run.candidate)
    guard !run.qualifies || run.candidate.falls == 0 else {
      fail("qualification contradicts reported falls")
    }
    ignore(checkpoint_path("policy", run.checkpoint))
    ignore(checkpoint_path("policy", run.latest_checkpoint))
  }
  for run in dynamics_runs {
    ignore(checkpoint_path("fit", run.checkpoint))
  }
  let dataset_path = if @fsx.path_exists(run_dir + "/collection/dataset.json") {
    "collection/dataset.json"
  } else {
    "collection/dataset.json.gz"
  }
  let payloads : Array[LearningPayload] = [
    seal(root, run_dir, "policy/report.json", "learning-policy-report"),
    seal(root, run_dir, dataset_path, "learning-transition-dataset"),
  ]
  if requires_dynamics {
    payloads.push(
      seal(root, run_dir, "fit/report.json", "learning-dynamics-report"),
    )
  }
  if balance {
    for
      (relative, kind) in [
        ("collection/balance-training.jsonl.gz", "learning-balance-training"),
        ("collection/training-sources.json", "learning-training-sources"),
        ("policy/balance-evaluation.jsonl.gz", "learning-balance-evaluation"),
        ("policy/balance-study.json", "learning-balance-study"),
      ] {
      payloads.push(seal(root, run_dir, relative, kind))
    }
    let selection = "policy/balance-selection.jsonl.gz"
    if @fsx.path_exists(run_dir + "/" + selection) {
      payloads.push(
        seal(root, run_dir, selection, "learning-balance-selection"),
      )
    }
  }
  if reference {
    payloads.append(seal_reference_evidence(root, run_dir))
  }
  if reference_learning {
    payloads.append(seal_reference_learning_evidence(root, run_dir))
  }
  let candidates : Array[LearningCandidate] = []
  for run in policy.runs {
    let selected = seal(
      root,
      run_dir,
      checkpoint_path("policy", run.checkpoint),
      "learning-policy-checkpoint",
    )
    payloads.push(selected)
    payloads.push(
      seal(
        root,
        run_dir,
        checkpoint_path("policy", run.latest_checkpoint),
        "learning-latest-policy-checkpoint",
      ),
    )
    payloads.push(
      seal(
        root,
        run_dir,
        "policy/physics-seed-\{run.seed}.json",
        "learning-physics-trace",
      ),
    )
    if physics_ppo {
      payloads.push(
        seal(
          root,
          run_dir,
          "policy/ppo-physics-seed-\{run.seed}.jsonl.gz",
          "learning-ppo-physics",
        ),
      )
    }
    if disturbance {
      for
        (relative, kind) in [
          (
            "policy/disturbance-physics-seed-\{run.seed}.jsonl.gz",
            "learning-supervised-physics",
          ),
          (
            "policy/disturbance-audit-seed-\{run.seed}.jsonl.gz",
            "learning-disturbance-audit",
          ),
        ] {
        payloads.push(seal(root, run_dir, relative, kind))
      }
    }
    let critic_physics = "policy/critic-physics-seed-\{run.seed}.jsonl.gz"
    if @fsx.path_exists(run_dir + "/" + critic_physics) {
      payloads.push(
        seal(root, run_dir, critic_physics, "learning-critic-physics"),
      )
    }
    candidates.push({
      seed: run.seed,
      selected_update: run.selected_update,
      baseline: run.baseline,
      candidate: run.candidate,
      survival_delta_s: run.candidate.mean_survival_s -
      run.baseline.mean_survival_s,
      producer_qualified: run.qualifies,
      checkpoint_ref: selected.data_ref,
    })
  }
  for run in dynamics_runs {
    payloads.push(
      seal(
        root,
        run_dir,
        checkpoint_path("fit", run.checkpoint),
        "learning-dynamics-checkpoint",
      ),
    )
    let latest = "fit/latest-dynamics-seed-\{run.seed}.pt"
    if @fsx.path_exists(run_dir + "/" + latest) {
      payloads.push(
        seal(root, run_dir, latest, "learning-latest-dynamics-checkpoint"),
      )
    }
  }
  if @fsx.path_exists(run_dir + "/policy/qualification-followup.json") {
    payloads.push(
      seal(
        root, run_dir, "policy/qualification-followup.json", "learning-qualification-followup",
      ),
    )
    for run in policy.runs {
      for mode in ["repeat-two-second", "fresh-two-second", "fresh-ten-second"] {
        let relative = "candidate-followup/seed-\{run.seed}-" +
          mode +
          "/physics.json"
        if @fsx.path_exists(run_dir + "/" + relative) {
          payloads.push(
            seal(root, run_dir, relative, "learning-followup-physics"),
          )
        }
      }
    }
  }
  let summary : LearningExperiment = {
    format: "moonrobo.learning-experiment.v1",
    experiment_id: id,
    source_id: source_id(id),
    imported_at_ms: now_ms,
    evidence_class: "physics-simulation",
    physical_execution_allowed: false,
    candidates,
    payloads,
  }
  let summary_blob = need(
    @blob.put_local_bytes(
      root,
      @utf8.encode(summary.to_json().stringify(indent=2)),
      kind="learning-summary",
      content_type="application/json",
    ),
  )
  let refs : Array[@data.DataRef] = [summary_blob.data_ref]
  for payload in payloads {
    if !refs.any(data_ref => data_ref.uri == payload.data_ref.uri) {
      refs.push(payload.data_ref)
    }
  }
  let source = @data.data_source(
    source_id(id),
    "learning-experiment",
    "Learning experiment " + id,
    "g1-simulation",
    "mujoco-cpu",
    "file://" + run_dir,
    now_ms,
    source_refs=refs,
  )
  ignore(need(@store.write_source(root, source)))
  ignore(need(@index.rebuild_catalog(root, now_ms)))
  summary
}

///|
/// Seal reports, transition data and binary weights in MoonData's BlobStore.
/// Reusing an id with changed inputs is rejected; import grants no actuation.
///
/// ```mbt nocheck
/// let experiment = @moondata_learning.import_run(
///   "book/moondata", "target/learning/run", "round-one", 1792689986000L,
/// ).unwrap()
/// assert_false(experiment.physical_execution_allowed)
/// ```
pub fn import_run(
  root : String,
  run_dir : String,
  id : String,
  now_ms : Int64,
) -> Result[LearningExperiment, String] {
  try import_experiment(root, run_dir, id, now_ms) catch {
    error => Err(error.to_string())
  } noraise {
    value => Ok(value)
  }
}

///|
/// List registered summaries through the existing canonical catalog.
///
/// ```mbt nocheck
/// let experiments = @moondata_learning.list("book/moondata").unwrap()
/// for experiment in experiments {
///   println(experiment.experiment_id)
/// }
/// ```
pub fn list(root : String) -> Result[Array[LearningExperiment], String] {
  try {
    let catalog = need(@store.read_catalog(root))
    let result : Array[LearningExperiment] = []
    for entry in catalog.entries {
      if entry.artifact_kind == "source" {
        let source = need(@store.read_source(root, entry.artifact_id))
        if source.kind == "learning-experiment" {
          let id = source.source_id
            .strip_prefix("learning-")
            .unwrap_or_else(() => fail("invalid learning source id"))
          result.push(read_experiment(root, id.to_owned()))
        }
      }
    }
    result
  } catch {
    error => Err(error.to_string())
  } noraise {
    value => Ok(value)
  }
}
