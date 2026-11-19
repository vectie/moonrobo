///|
/// Standalone checkpoint actions share the same real runtime and episode RNG law as training. Evaluation explicitly spans every experiment case, matching the original policy.py default split=None.
fn assert_checkpoint_body(
  runtime : @native_physics.Runtime,
  actor : @training.Actor,
) -> Unit raise {
  let (nq, _, _, _) = runtime.dimensions()
  guard actor.body.nq == nq &&
    actor.body.q_indices == runtime.q_indices() &&
    actor.body.v_state_indices == runtime.v_indices().map(i => nq + i) else {
    fail("checkpoint body differs from evaluator")
  }
}

///|
pub async fn evaluate_checkpoint(
  library : String,
  scene : String,
  checkpoint_path : String,
  config_path : String,
  experiment_path : String,
  output : String,
) -> Json {
  let checkpoint = @training.load_learning_checkpoint(
    checkpoint_path, "g1-actor",
  )
  let actor = @training.actor_from_checkpoint(checkpoint)
  let config = @artifacts.load_json(config_path)
  let experiment = @artifacts.load_json(experiment_path)
  let runtime = @native_physics.Runtime::open(library, scene)
  assert_checkpoint_body(runtime, actor)
  let cases : Array[Json] = @json.from_json(field(experiment, "cases"))
  let seeds : Array[Int32] = @json.from_json(field(config, "test_seeds"))
  let (baseline, _, baseline_trials) = evaluate(
    runtime,
    cases,
    seeds,
    experiment,
    None,
    "all",
    @numeric.Rng::new(31415U),
  )
  let (candidate, _, candidate_trials) = evaluate(
    runtime,
    cases,
    seeds,
    experiment,
    Some(actor),
    "all",
    @numeric.Rng::new(31415U),
  )
  let report : Json = {
    "format": "moonrobo.g1-checkpoint-evaluation.v1",
    "baseline": physics_group(baseline, baseline_trials),
    "candidate": physics_group(candidate, candidate_trials),
    "checkpoint_sha256": @artifacts.sha256(
      @fs.read_file(checkpoint_path).binary(),
    ).to_json(),
    "experiment": experiment,
    "evaluation_seeds": seeds.to_json(),
    "evaluation_case_scope": "all-experiment-cases",
    "evaluation_action_noise_std_rad": 0.0,
    "body": {
      "q_indices": actor.body.q_indices.to_json(),
      "v_state_indices": actor.body.v_state_indices.to_json(),
      "nq": actor.body.nq.to_json(),
    },
    "policy_config": field(checkpoint.metadata, "config"),
    "model_ref": field(checkpoint.metadata, "model_ref"),
    "numeric_backend": "native-moonbit-float64",
  }
  if !@fs.exists(output) {
    @fs.mkdir(output, recursive=true)
  }
  ignore(@artifacts.save_json(output + "/physics.json", report))
  report
}

///|
pub async fn collect_checkpoint(
  library : String,
  scene : String,
  checkpoint_path : String,
  experiment_path : String,
  output : String,
  split~ : String = "train",
) -> Json {
  guard ["train", "validation", "test"].contains(split) else {
    fail("invalid collection split")
  }
  let actor = @training.actor_from_checkpoint(
    @training.load_learning_checkpoint(checkpoint_path, "g1-actor"),
  )
  let experiment = @artifacts.load_json(experiment_path)
  let runtime = @native_physics.Runtime::open(library, scene)
  assert_checkpoint_body(runtime, actor)
  let digest = @artifacts.sha256(@fs.read_file(checkpoint_path).binary())
  let cases : Array[Json] = @json.from_json(field(experiment, "cases"))
  let seeds : Array[Int32] = @json.from_json(field(experiment, "seeds"))
  let episodes : Array[@native_physics.Episode] = []
  let trials : Array[@native_physics.Trial] = []
  for case in cases {
    if text(case, "split") != split {
      continue
    }
    for seed in seeds {
      let (episode, trial) = rollout(
        runtime,
        case,
        seed,
        experiment,
        Some(actor),
        @numeric.Rng::new(seed.to_uint()),
        action_noise_std=optional_number(experiment, "action_noise_std_rad", 0),
      )
      let id = episode.id + "-" + digest[:12].to_owned()
      episodes.push({ ..episode, id, })
      trials.push({ ..trial, episode_id: id, })
    }
  }
  guard !episodes.is_empty() else { fail("collection selected no episodes") }
  let dataset = runtime.dataset(
    episodes,
    text(experiment, "source_revision"),
    dt=number(experiment, "control_dt_s"),
  )
  if dataset is Object(fields) {
    fields["policy_checkpoint_sha256"] = digest.to_json()
    fields["collection_split"] = split.to_json()
  }
  let summary : Json = {
    "episodes": episodes.length().to_json(),
    "transitions": episodes
    .fold(init=0, (sum, e) => sum + e.steps.length())
    .to_json(),
    "falls": trials.filter(t => t.failed).length().to_json(),
    "split": split.to_json(),
    "policy_sha256": digest.to_json(),
  }
  if !@fs.exists(output) {
    @fs.mkdir(output, recursive=true)
  }
  ignore(@artifacts.save_json(output + "/dataset.json", dataset))
  ignore(
    @artifacts.save_json(output + "/report.json", {
      "summary": summary,
      "experiment": experiment,
      "trials": trials.to_json(),
    }),
  )
  summary
}
