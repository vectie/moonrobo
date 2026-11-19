///|
pub fn config_bool(config : Json, name : String, fallback : Bool) -> Bool raise {
  match config {
    Object(fields) =>
      match fields.get(name) {
        Some(value) => json_boolean(value)
        None => fallback
      }
    _ => fail("configuration object")
  }
}

///|
fn fit_error_json(
  actor : ReferenceActor,
  points : Array[TrainingPoint],
) -> Json {
  let (rms, maximum) = fit_error(actor, points)
  { "action_rmse_rad": rms, "max_action_error_rad": maximum }
}

///|
/// Original fixed-final-update initialization protocol, including all training
/// seeds, reference-only decoder masking, reload verification and the unchanged
/// physical coverage suite. feedback is a normalized native feedback spec;
/// Torch interchange decoding is kept outside the training algorithm.
pub async fn run_initialization_study(
  config_path : String,
  quality_path : String,
  references_path : String,
  feedback_path : String,
  feedback : Json,
  runtime : @physics.Runtime,
  output : String,
  provider_source : String,
) -> Json {
  let started = @async.now()
  let config = @artifacts.load_json(config_path)
  let quality = @artifacts.load_json(quality_path)
  let manifest_sha = source_digest(references_path + "/manifest.json")
  guard manifest_sha ==
    json_text(json_field(quality, "reference_manifest_sha256")) else {
    fail("reference quality target belongs to another manifest")
  }
  let (manifest, references) = load_references(references_path)
  let dt = json_number(json_field(json_field(manifest, "layout"), "dt_s"))
  let kinematics = json_field(feedback, "kinematics")
  let geometry = kinematics_from_spec(kinematics)
  let coefficients : Array[Array[Double]] = @json.from_json(
    json_field(feedback, "feedback_coefficients"),
  )
  let indices : Array[Int32] = @json.from_json(json_field(feedback, "indices"))
  let history_length = json_integer(json_field(config, "history_length"))
  let future_length = json_integer(json_field(config, "future_length"))
  let points : Array[TrainingPoint] = []
  for reference in references {
    points.append(
      training_points(
        reference.matrix("observation"),
        reference.goals(),
        reference.matrix("source_setpoint"),
        history_length,
        future_length,
      ),
    )
  }
  let output_bound = json_number(json_field(config, "output_bound_rad"))
  let mut maximum_target_residual = 0.0
  for point in points {
    for i, target in point.target {
      maximum_target_residual = maximum_target_residual.max(
        (target - point.current[i]).abs(),
      )
    }
  }
  guard maximum_target_residual < output_bound else {
    fail("declared action residual cannot represent source labels")
  }
  let provenance : Json = {
    "reference_manifest_sha256": manifest_sha,
    "feedback_checkpoint_sha256": source_digest(feedback_path),
    "quality_sha256": source_digest(quality_path),
    "training_points": points.length(),
    "fit": "supervised source-control labels; fixed final update; all references are train families",
  }
  @fs.mkdir(output + "/policy", recursive=true)
  let fits : Array[Json] = []
  let evaluations : Array[Json] = []
  let seeds = json_array(json_field(config, "seeds"))
  guard !seeds.is_empty() else { fail("initialization needs training seeds") }
  let reference_only = config_bool(
    config, "reference_only_initialization", false,
  )
  let (lower, upper) = runtime.control_bounds()
  for seed_json in seeds {
    let seed = json_integer(seed_json)
    let rng = @numeric.Rng::new(seed.reinterpret_as_uint())
    let actor = ReferenceActor::new(
      points[0].current.length(),
      geometry.nu,
      lower,
      upper,
      coefficients,
      indices,
      rng,
      history_length~,
      future_length~,
      width=json_integer(json_field(config, "width")),
      latent_dim=json_integer(json_field(config, "latent_dim")),
      output_bound~,
    )
    actor.fit_normalization(
      points,
      json_number(json_field(config, "normalization_floor")),
    )
    if reference_only {
      let latent_dim = actor.goal_encoder[actor.goal_encoder.length() - 1].bias.length()
      for row in actor.decoder[0].weight {
        for j in latent_dim..<row.length() {
          row[j] = 0.0
        }
      }
    }
    if seed_json == seeds[0] {
      ignore(
        save_reference_actor(
          output + "/policy/actor-zero-output.json",
          actor,
          kinematics,
          dt,
          provenance,
        ),
      )
    }
    let before = fit_error_json(actor, points)
    let history : Array[Json] = []
    let optimizer = @numeric.Adam::new(
      actor.parameters().length(),
      json_number(json_field(config, "learning_rate")),
    )
    let sampler = @numeric.Rng::new((seed + 987).reinterpret_as_uint())
    let updates = json_integer(json_field(config, "updates"))
    let fit_started = @async.now()
    for update in 1..<=updates {
      let rows = Array::makei(json_integer(json_field(config, "batch_size")), _ => {
        points[sampler.index(points.length())]
      })
      let loss = supervised_actor_step(actor, optimizer, rows, reference_only~)
      if update % 100 == 0 {
        let row : Json = {
          "seed": seed,
          "update": update,
          "batch_action_mse_rad2": loss,
        }
        history.push(row)
        println(row.stringify())
      }
    }
    let fit_seconds = (@async.now() - fit_started).to_double() / 1000.0
    let file = "policy/actor-seed-\{seed}.json"
    let actor_provenance = json_fields(provenance)
    actor_provenance["seed"] = seed.to_json()
    actor_provenance["updates"] = updates.to_json()
    let hash = save_reference_actor(
      output + "/" + file,
      actor,
      kinematics,
      dt,
      actor_provenance.to_json(),
    )
    let (restored, _) = load_reference_actor(
      output + "/" + file,
      expected_sha256=hash,
    )
    guard restored.to_json() == actor.to_json() else {
      fail("reference actor checkpoint changed on reload")
    }
    fits.push({
      "seed": seed,
      "updates": updates,
      "before": before,
      "after": fit_error_json(restored, points),
      "fit_seconds": fit_seconds,
      "history": history,
      "checkpoint": file,
      "checkpoint_sha256": hash,
    })
    let eval_started = @async.now()
    let evaluated = json_fields(
      evaluate_initialization(
        runtime,
        references,
        restored,
        geometry,
        quality,
        output,
        "seed-\{seed}",
        dt,
      ),
    )
    evaluated["evaluation_seconds"] = ((@async.now() - eval_started).to_double() /
    1000.0).to_json()
    evaluations.push(evaluated.to_json())
  }
  let (zero, _) = load_reference_actor(
    output + "/policy/actor-zero-output.json",
  )
  let eval_started = @async.now()
  let baseline = json_fields(
    evaluate_initialization(
      runtime, references, zero, geometry, quality, output, "zero-output", dt,
    ),
  )
  baseline["evaluation_seconds"] = ((@async.now() - eval_started).to_double() /
  1000.0).to_json()
  let report = json_fields(provenance)
  report["format"] = "moonrobo.g1-reference-initialization.v1".to_json()
  report["checkpoint_format"] = "moonrobo.g1-reference-actor.moonbit.v1".to_json()
  report["config"] = config
  report["quality_target"] = quality
  report["maximum_target_residual_rad"] = maximum_target_residual.to_json()
  report["provider_sha256"] = source_digest(provider_source).to_json()
  report["fits"] = fits.to_json()
  report["evaluations"] = evaluations.to_json()
  report["baseline"] = baseline.to_json()
  report["provider_seconds"] = ((@async.now() - started).to_double() / 1000.0).to_json()
  report["rng_semantics"] = "native xorshift32/Box-Muller; Torch seed equivalence is not claimed".to_json()
  report["release_qualified"] = false.to_json()
  report["physical_execution_allowed"] = false.to_json()
  let result = report.to_json()
  ignore(@artifacts.save_json(output + "/report.json", result))
  result
}
