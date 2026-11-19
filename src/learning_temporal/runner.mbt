///|
pub(all) struct OfflineFitConfig {
  updates : Int32
  batch_size : Int32
  learning_rate : Double
  seed : UInt32
} derive(Debug, FromJson, ToJson)

///|
pub(all) struct TemporalDataset {
  split : String
  points : Array[TemporalPoint]
} derive(Debug, FromJson, ToJson)

///|
pub(all) struct ValueDataset {
  split : String
  points : Array[ValuePoint]
} derive(Debug, FromJson, ToJson)

///|
async fn read_json(path : String) -> Json {
  let raw = @fs.read_file(path).binary()
  let bytes = if path.has_suffix(".gz") {
    @artifacts.decompress(raw)
  } else {
    raw
  }
  @json.parse(@utf8.decode(bytes))
}

///|
/// Offline supervision driver. It deliberately reports no simulation qualification; online DAgger selection is provided by fit_temporal's physics callbacks.
pub async fn run_fit_temporal(
  incoming : String,
  points_path : String,
  config_path : String,
  output : String,
) -> Json {
  let data : TemporalDataset = @json.from_json(read_json(points_path))
  let config : OfflineFitConfig = @json.from_json(read_json(config_path))
  guard data.split == "train" &&
    !data.points.is_empty() &&
    config.batch_size > 0 &&
    config.updates >= 0 else {
    fail("temporal fit requires nonempty training-only points and valid config")
  }
  let actor = load_temporal(incoming)
  let rng = @numeric.Rng::new(config.seed)
  let optimizer = @numeric.Adam::new(
    actor.parameters().length(),
    config.learning_rate,
  )
  let losses : Array[Double] = []
  for _ in 0..<config.updates {
    let batch = Array::makei(config.batch_size, fn(_) {
      data.points[rng.index(data.points.length())]
    })
    losses.push(actor.clone_update(optimizer, batch))
  }
  let metadata : Json = {
    "config": config.to_json(),
    "source_checkpoint": incoming.to_json(),
    "data": points_path.to_json(),
    "physical_execution_allowed": false,
    "validation_physics_performed": false,
  }
  let digest = save_temporal(output, actor, metadata)
  let restored = load_temporal(output)
  let point = data.points[0]
  guard actor.predict(point.history, point.goal, point.future) ==
    restored.predict(point.history, point.goal, point.future) else {
    fail("temporal checkpoint reload differs")
  }
  let report : Json = {
    "format": "moonrobo.moonbit-temporal-offline-fit.v1",
    "updates": config.updates.to_json(),
    "points": data.points.length().to_json(),
    "losses": losses.to_json(),
    "checkpoint_sha256": digest.to_json(),
    "reload_matches": true,
    "physical_execution_allowed": false,
    "validation_physics_performed": false,
  }
  @fs.write_file(
    output + ".report.json",
    @utf8.encode(report.stringify()),
    create_mode=CreateOrTruncate,
  )
  report
}

///|
pub async fn run_fit_value(
  incoming : String,
  points_path : String,
  config_path : String,
  output : String,
) -> Json {
  let data : ValueDataset = @json.from_json(read_json(points_path))
  let config : OfflineFitConfig = @json.from_json(read_json(config_path))
  guard data.split == "train" &&
    !data.points.is_empty() &&
    config.batch_size > 0 &&
    config.updates >= 0 else {
    fail("value fit requires nonempty training-only points and valid config")
  }
  let incoming_checkpoint = @artifacts.load_checkpoint(
    incoming, "temporal-value",
  )
  let value = value_from_checkpoint(incoming_checkpoint)
  let before = value.error(data.points)
  let rng = @numeric.Rng::new(config.seed)
  let optimizer = @numeric.Adam::new(
    value.net.parameters.length(),
    config.learning_rate,
  )
  for _ in 0..<config.updates {
    ignore(
      value.fit_update(
        optimizer,
        Array::makei(config.batch_size, fn(_) {
          data.points[rng.index(data.points.length())]
        }),
      ),
    )
  }
  let metadata = match incoming_checkpoint.metadata {
    Object(fields) => {
      let fields = fields.copy()
      fields["fit_config"] = config.to_json()
      fields["data_path"] = points_path.to_json()
      fields["calibrated"] = (config.updates > 0).to_json()
      Json::object(fields)
    }
    _ => incoming_checkpoint.metadata
  }
  let digest = save_value(output, value, metadata)
  let restored = load_value(output)
  let point = data.points[0]
  guard value.predict(
      point.state,
      point.history,
      point.goals,
      point.context,
      point.remaining,
    ) ==
    restored.predict(
      point.state,
      point.history,
      point.goals,
      point.context,
      point.remaining,
    ) else {
    fail("value checkpoint reload differs")
  }
  let report : Json = {
    "format": "moonrobo.moonbit-temporal-value-fit.v1",
    "points": data.points.length().to_json(),
    "updates": config.updates.to_json(),
    "before_rmse": before.to_json(),
    "after_rmse": value.error(data.points).to_json(),
    "checkpoint_sha256": digest.to_json(),
    "reload_matches": true,
    "physical_execution_allowed": false,
  }
  @fs.write_file(
    output + ".report.json",
    @utf8.encode(report.stringify()),
    create_mode=CreateOrTruncate,
  )
  report
}

///|
pub(all) struct InitializationConfig {
  history_length : Int32
  future_length : Int32
  adapter_width : Int32
  seed : UInt32
} derive(Debug, FromJson, ToJson)

///|
/// Initialize the zero temporal adapter from a native MoonBit legacy actor checkpoint. The initialized adapter preserves parent actions exactly.
pub async fn run_initialize(
  incoming : String,
  config_path : String,
  output : String,
) -> Json {
  let config : InitializationConfig = @json.from_json(read_json(config_path))
  let checkpoint = @artifacts.load_checkpoint(incoming, "g1-actor")
  let base = @training.actor_from_checkpoint(checkpoint)
  let actor = TemporalPolicy::new(
    base,
    config.history_length,
    config.future_length,
    config.adapter_width,
    @numeric.Rng::new(config.seed),
  )
  let digest = save_temporal(output, actor, {
    "initialization": incoming.to_json(),
    "config": config.to_json(),
    "physical_execution_allowed": false,
    "adapter_zero_initialized": true,
  })
  {
    "checkpoint_sha256": digest.to_json(),
    "adapter_zero_initialized": true,
    "physical_execution_allowed": false,
  }
}

///|
pub(all) struct ValueInitializationConfig {
  width : Int32
  gamma : Double
  duration : Double
  dt : Double
  seed : UInt32
} derive(Debug, ToJson, FromJson)

///|
pub async fn run_initialize_value(
  actor_path : String,
  dynamics_path : String,
  config_path : String,
  output : String,
) -> Json {
  let config : ValueInitializationConfig = @json.from_json(
    read_json(config_path),
  )
  guard config.gamma > 0.0 &&
    config.gamma < 1.0 &&
    config.duration > 0.0 &&
    config.dt > 0.0 else {
    fail("invalid finite value configuration")
  }
  let actor = load_temporal(actor_path)
  let model = @training.dynamics_from_checkpoint(
    @artifacts.load_checkpoint(dynamics_path, "residual-dynamics"),
  )
  let value = make_value(
    model,
    actor,
    config.width,
    config.gamma,
    config.duration,
    @numeric.Rng::new(config.seed),
    dt=config.dt,
  )
  let actor_digest = @artifacts.sha256(@fs.read_file(actor_path).binary())
  let digest = save_value(output, value, {
    "actor_checkpoint_sha256": actor_digest.to_json(),
    "critic_actor_update": 0,
    "config": config.to_json(),
    "physical_execution_allowed": false,
    "calibrated": false,
  })
  {
    "checkpoint_sha256": digest.to_json(),
    "actor_checkpoint_sha256": actor_digest.to_json(),
    "calibrated": false,
    "physical_execution_allowed": false,
  }
}
