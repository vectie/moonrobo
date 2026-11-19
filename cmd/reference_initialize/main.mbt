///|
struct Config {
  references : String
  kinematics : Json
  lower : Array[Double]
  upper : Array[Double]
  feedback_coefficients : Array[Array[Double]]
  indices : Array[Int32]
  seed : UInt32
  updates : Int32
  batch_size : Int32
  history_length : Int32
  future_length : Int32
  width : Int32
  latent_dim : Int32
  output_bound : Double
  normalization_floor : Double
  learning_rate : Double
  output_checkpoint : String
  output_report : String
} derive(FromJson)

///|
async fn main {
  let args = @env.args()
  if args.length() == 10 && args[1] == "study" {
    let runtime = @physics.Runtime::open(args[6], args[7])
    let feedback = @reference.load_initialization_feedback(args[5])
    let report = @reference.run_initialization_study(
      args[2],
      args[3],
      args[4],
      args[5],
      feedback,
      runtime,
      args[8],
      args[9],
    )
    println(report.stringify())
    return
  }
  guard args.length() == 2 else {
    fail(
      "usage: moon run --target native cmd/reference_initialize -- CONFIG.json",
    )
  }
  let config : Config = @json.from_json(
    @json.parse(@utf8.decode(@fs.read_file(args[1]).binary())),
  )
  guard config.updates >= 0 && config.batch_size > 0 else {
    fail("nonnegative updates and positive batch size required")
  }
  let (manifest, references) = @reference.load_references(config.references)
  let geometry = @reference.kinematics_from_spec(config.kinematics)
  let points : Array[@reference.TrainingPoint] = []
  for reference in references {
    points.append(
      @reference.training_points(
        reference.matrix("observation"),
        reference.goals(),
        reference.matrix("source_setpoint"),
        config.history_length,
        config.future_length,
        nu=geometry.nu,
      ),
    )
  }
  let rng = @numeric.Rng::new(config.seed)
  let actor = @reference.ReferenceActor::new(
    points[0].current.length(),
    geometry.nu,
    config.lower,
    config.upper,
    config.feedback_coefficients,
    config.indices,
    rng,
    history_length=config.history_length,
    future_length=config.future_length,
    width=config.width,
    latent_dim=config.latent_dim,
    output_bound=config.output_bound,
  )
  actor.fit_normalization(points, config.normalization_floor)
  for point in points {
    for i, target in point.target {
      guard (target - point.current[i]).abs() < config.output_bound else {
        fail("declared action residual cannot represent source labels")
      }
    }
  }
  let before = @reference.fit_error(actor, points)
  let optimizer = @numeric.Adam::new(
    actor.parameters().length(),
    config.learning_rate,
  )
  let history : Array[Json] = []
  for update in 1..<=config.updates {
    let batch = Array::makei(config.batch_size, _ => {
      points[rng.index(points.length())]
    })
    let loss = @reference.supervised_actor_step(actor, optimizer, batch)
    if update % 100 == 0 || update == config.updates {
      history.push({ "update": update, "batch_action_mse_rad2": loss })
    }
  }
  let after = @reference.fit_error(actor, points)
  let dt = match references[0].layout {
    Object(fields) =>
      match fields.get("dt_s") {
        Some(Number(value, ..)) => value
        _ => fail("reference dt_s")
      }
    _ => fail("reference layout")
  }
  let digest = @reference.save_reference_actor(
    config.output_checkpoint,
    actor,
    config.kinematics,
    dt,
    {
      "training": "supervised source labels",
      "reference_manifest": manifest,
      "seed": config.seed,
      "updates": config.updates,
      "rng": "MoonBit xorshift32; not Torch seed-equivalent",
    },
  )
  let (restored, _) = @reference.load_reference_actor(
    config.output_checkpoint,
    expected_sha256=digest,
  )
  guard restored.parameters() == actor.parameters() else {
    fail("actor checkpoint changed on reload")
  }
  let report : Json = {
    "format": "moonrobo.g1-reference-initialization.moonbit.v1",
    "checkpoint": config.output_checkpoint,
    "sha256": digest,
    "training_points": points.length(),
    "before_action_rmse_rad": before.0,
    "before_max_action_error_rad": before.1,
    "after_action_rmse_rad": after.0,
    "after_max_action_error_rad": after.1,
    "history": history,
    "physical_execution_allowed": false,
    "release_qualified": false,
    "physics_evaluated": false,
  }
  @fs.write_file(
    config.output_report,
    @utf8.encode(report.stringify(indent=2)),
    create_mode=CreateOrTruncate,
  )
  println(report.stringify())
}
