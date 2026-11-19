///|
fn field(value : Json, name : String) -> Json raise {
  guard value is Object(fields) && fields.get(name) is Some(result) else {
    fail("missing registry field: " + name)
  }
  result
}

///|
fn array(value : Json) -> Array[Json] raise {
  guard value is Array(items) else { fail("registry array required") }
  items
}

///|
fn text(value : Json) -> String raise {
  guard value is String(value) else { fail("registry string required") }
  value
}

///|
fn number(value : Json) -> Double raise {
  guard value is Number(value, ..) && value.abs() <= 1.7976931348623157e308 else {
    fail("finite registry number required")
  }
  value
}

///|
fn seed(value : Json) -> Int32 raise {
  let n = number(value)
  guard n >= 0 && n <= 2147483647.0 && n.to_int().to_double() == n else {
    fail("nonnegative integer seed required")
  }
  n.to_int()
}

///|
pub fn trial_summary(trials : Array[Json]) -> Json raise {
  guard !trials.is_empty() else {
    fail("cannot summarize empty registry trials")
  }
  let mut falls = 0
  let mut survival = 0.0
  let mut rmse = 0.0
  for trial in trials {
    match field(trial, "failed") {
      True => falls += 1
      False => ()
      _ => fail("boolean failure required")
    }
    survival += number(field(trial, "simulated_seconds"))
    rmse += number(field(trial, "joint_rmse_rad"))
  }
  {
    "trials": Json(trials.length()),
    "falls": Json(falls),
    "mean_survival_s": Json(survival / trials.length().to_double()),
    "mean_joint_rmse_rad": Json(rmse / trials.length().to_double()),
  }
}

///|
pub fn reconstruct_replay(
  runtime : @physics.Runtime,
  episode : Json,
  dt : Double,
) -> Json raise {
  let context = array(field(episode, "context"))
  guard !context.is_empty() && dt > 0 else {
    fail("registry replay requires friction context and positive cadence")
  }
  runtime.set_friction(number(context[0]))
  let (nq, _, _, _) = runtime.dimensions()
  let replay : Array[Json] = []
  for step in array(field(episode, "steps")) {
    let state = array(field(step, "next_state")).map(number)
    runtime.set_state(state)
    replay.push({
      "time_s": Json(number(field(step, "time_s")) + dt),
      "qpos": Json(Array::makei(nq, i => state[i])),
      "target": field(step, "goal"),
      "root_height_m": Json(runtime.root_height()),
      "upright_z": Json(runtime.upright()),
      "contacts": Json(runtime.contacts()),
    })
  }
  Json(replay)
}

///|
async fn digest(path : String) -> String {
  @artifacts.sha256(@fs.read_file(path).binary())
}

///|
fn basename(path : String) -> String {
  path.split("/").last().unwrap().to_owned()
}

///|
/// Translation of sustained_balance_export.py. Reconstructs recorded contact
/// geometry without stepping or evaluating policy weights; source proofs remain
/// mandatory. Registry schema and qualification semantics follow the original.
pub async fn export_sustained(
  study : String,
  library : String,
  scene : String,
  output : String,
  provider_source~ : String = "src/learning_registry/sustained_export.mbt",
) -> Json {
  let report = @artifacts.load_json(study + "/report.json")
  let proof = @artifacts.load_json(study + "/refit-verification.json")
  guard field(proof, "all_tensors_exact") == true &&
    array(field(proof, "verified_checkpoints")).length() == 15 else {
    fail("missing train-only checkpoint reproduction")
  }
  let charter = @artifacts.load_json(study + "/charter.json")
  let experiment = @artifacts.load_json(
    text(field(charter, "original_balance_study")) + "/experiment.json",
  )
  let config = field(report, "config")
  let dt = number(field(experiment, "control_dt_s"))
  for
    (name, key) in [
      ("teacher-training.jsonl.gz", "training_sha256"),
      ("selection-physics.jsonl.gz", "selection_sha256"),
      ("evaluation-physics.jsonl.gz", "evaluation_sha256"),
    ] {
    guard digest(study + "/" + name) == text(field(report, key)) else {
      fail("sustained source physics changed: " + name)
    }
  }
  guard provider_source.has_suffix(".mbt") else {
    fail("native exporter provenance must name its actual MoonBit source")
  }
  @fs.mkdir(output + "/provider-sources", recursive=true)
  @fs.write_file(
    output + "/provider-sources/sustained_balance_export.mbt",
    @fs.read_file(provider_source).binary(),
    create_mode=CreateOrTruncate,
  )
  @fs.mkdir(output + "/policy", recursive=true)
  @fs.mkdir(output + "/collection", recursive=true)
  let training = @utf8.decode(
    @artifacts.decompress(
      @fs.read_file(study + "/teacher-training.jsonl.gz").binary(),
    ),
  )
  guard training.split("\n").next() is Some(first) && !first.trim().is_empty() else {
    fail("empty teacher training archive")
  }
  let representative_sha = @artifacts.save_json(
    output + "/collection/dataset.json.gz",
    field(@json.parse(first.to_owned()), "dataset"),
  )
  let runtime = @physics.Runtime::open(library, scene)
  let baseline : Array[Json] = []
  let candidates : Map[Int32, Array[Json]] = {}
  let seeds = array(field(config, "seeds")).map(seed)
  for s in seeds {
    guard !candidates.contains(s) else { fail("duplicate sustained seed") }
    candidates[s] = []
  }
  for record in @artifacts.load_jsonl(study + "/evaluation-physics.jsonl.gz") {
    if text(field(record, "scope")) != "canonical-development" {
      continue
    }
    let episodes = array(field(field(record, "dataset"), "episodes"))
    let trials = array(field(record, "trials"))
    guard episodes.length() == 1 &&
      trials.length() == 1 &&
      field(trials[0], "episode_id") == field(episodes[0], "id") else {
      fail("sustained replay identity mismatch")
    }
    guard trials[0] is Object(fields) else { fail("trial must be object") }
    let fields = fields.copy()
    fields["replay"] = reconstruct_replay(runtime, episodes[0], dt)
    let trial = Json::object(fields)
    if text(field(record, "role")) == "teacher-reference" {
      baseline.push(trial)
    } else {
      guard candidates.get(seed(field(record, "seed"))) is Some(target) else {
        fail("unexpected sustained parent seed")
      }
      target.push(trial)
    }
  }
  guard baseline.length() == 9 else {
    fail("expected nine unique teacher-reference trials")
  }
  let baseline_summary = trial_summary(baseline)
  let runs : Array[Json] = []
  for s in seeds {
    let trials = candidates.get(s).unwrap()
    guard trials.length() == 9 else {
      fail("expected nine selected canonical trials per parent")
    }
    let matching = array(field(report, "final")).filter(row => {
      field(row, "role") == "selected-final" &&
      field(row, "seed") == Json(s) &&
      field(row, "scope") == "canonical-development"
    })
    guard matching.length() == 1 else {
      fail("unique selected-final canonical row required")
    }
    let row = matching[0]
    let summary = trial_summary(trials)
    guard summary == field(row, "summary") else {
      fail("exported selected summary differs")
    }
    let trace : Json = {
      "baseline": { "summary": baseline_summary, "trials": Json(baseline) },
      "candidate": { "summary": summary, "trials": Json(trials) },
      "baseline_role": "privileged selected teacher; nine unique conditions reused across parent comparisons",
      "replay_source": "geometry/contact reconstruction from recorded next_state; no policy rerun",
      "physical_execution_allowed": false,
    }
    ignore(
      @artifacts.save_json(output + "/policy/physics-seed-\{s}.json", trace),
    )
    let checkpoint = text(field(field(row, "checkpoint"), "path"))
    let name = basename(checkpoint)
    let qualifies = number(field(summary, "falls")) == 0 &&
      number(field(summary, "mean_joint_rmse_rad")) <=
      number(field(config, "max_mean_joint_rmse_rad"))
    runs.push({
      "seed": Json(s),
      "selected_update": 1,
      "baseline": baseline_summary,
      "candidate": summary,
      "qualifies": Json(qualifies),
      "checkpoint": Json(name),
      "latest_checkpoint": Json(name),
      "checkpoint_sha256": Json(digest(checkpoint)),
    })
  }
  guard experiment is Object(experiment_fields) else {
    fail("experiment must be object")
  }
  let experiment_fields = experiment_fields.copy()
  experiment_fields["duration_s"] = field(config, "duration_s")
  let policy : Json = {
    "format": "moonrobo.g1-learned-balance-fit.v1",
    "runs": Json(runs),
    "experiment": Json::object(experiment_fields),
    "checkpoint_format": "moonrobo.g1-learned-balance-actor.v2",
    "selected_variant": field(report, "selected_variant"),
    "head_fit_count": 1,
    "seed_semantics": "frozen parent seed; one shared selected sixteen-coefficient ankle law",
    "selected_update_semantics": "one closed-form fit; architecture chosen on separate train-family conditions before final runs",
    "baseline_role": "privileged selected teacher, not the original parent actor",
    "collection_role": "first teacher-training episode only; complete eighteen-episode fit corpus in balance-training.jsonl.gz; labels are actual applied teacher actions",
    "selection_role": "all 135 train-family architecture-selection episodes, excluded from fitting, in balance-selection.jsonl.gz",
    "evaluation_role": "all 90 selected-policy/teacher-reference canonical and audit episodes in balance-evaluation.jsonl.gz",
    "training_sha256": field(report, "training_sha256"),
    "selection_sha256": field(report, "selection_sha256"),
    "evaluation_sha256": field(report, "evaluation_sha256"),
    "research_report_sha256": Json(digest(study + "/report.json")),
    "refit_verification_sha256": Json(
      digest(study + "/refit-verification.json"),
    ),
    "qualification_scope": "thirty-second development canonical suite: zero falls and mean joint RMSE <= 0.15 rad",
    "release_qualified": false,
    "physical_execution_allowed": false,
  }
  ignore(@artifacts.save_json(output + "/policy/report.json", policy))
  let metadata : Json = {
    "format": "moonrobo.g1-sustained-balance-export.v1",
    "source_report_sha256": Json(digest(study + "/report.json")),
    "source_refit_sha256": Json(digest(study + "/refit-verification.json")),
    "provider_sha256": Json(digest(provider_source)),
    "provider_source": Json(provider_source),
    "provider_snapshot": "provider-sources/sustained_balance_export.mbt",
    "source_language": "moonbit",
    "representative_sha256": Json(representative_sha),
    "runs": Json(runs),
    "physical_execution_allowed": false,
  }
  ignore(@artifacts.save_json(output + "/export.json", metadata))
  metadata
}
