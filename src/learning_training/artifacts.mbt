///|
fn json_field(value : Json, key : String) -> Json raise {
  guard value is Object(fields) && fields.get(key) is Some(result) else {
    fail("missing learning field: " + key)
  }
  result
}

///|
fn json_int(value : Json) -> Int32 raise {
  guard value is Number(v, ..) &&
    v >= 0 &&
    v <= 2147483647.0 &&
    v.to_int().to_double() == v else {
    fail("learning integer required")
  }
  v.to_int()
}

///|
fn json_double(value : Json) -> Double raise {
  guard value is Number(v, ..) && @numeric.finite(v) else {
    fail("finite learning number required")
  }
  v
}

///|
fn json_array(value : Json) -> Array[Json] raise {
  guard value is Array(items) else { fail("learning array required") }
  items
}

///|
fn json_bool_default(value : Json, key : String, fallback : Bool) -> Bool raise {
  guard value is Object(fields) else { fail("learning object required") }
  match fields.get(key) {
    None => fallback
    Some(True) => true
    Some(False) => false
    _ => fail("boolean required: " + key)
  }
}

///|
fn json_double_default(
  value : Json,
  key : String,
  fallback : Double,
) -> Double raise {
  guard value is Object(fields) else { fail("learning object required") }
  match fields.get(key) {
    None => fallback
    Some(v) => json_double(v)
  }
}

///|
pub fn windows_from_batch(
  batch : @artifacts.WindowBatch,
) -> Array[Window] raise {
  let ns = json_array(json_field(batch.layout, "state_axes")).length()
  let na = json_array(json_field(batch.layout, "action_axes")).length()
  let nc = json_array(json_field(batch.layout, "context_axes")).length()
  Array::makei(batch.count, i => {
    state: Array::makei(batch.horizon, t => {
      Array::makei(ns, j => batch.state[(i * batch.horizon + t) * ns + j])
    }),
    action: Array::makei(batch.horizon, t => {
      Array::makei(na, j => batch.action[(i * batch.horizon + t) * na + j])
    }),
    target: Array::makei(batch.horizon, t => {
      Array::makei(ns, j => batch.target[(i * batch.horizon + t) * ns + j])
    }),
    context: Array::makei(nc, j => batch.context[i * nc + j]),
    start_time_s: batch.start_time_s[i],
  })
}

///|
pub fn Dynamics::checkpoint(
  self : Dynamics,
  metadata : Json,
) -> @artifacts.Checkpoint raise {
  let checkpoint = @artifacts.Checkpoint::new("residual-dynamics", metadata)
  checkpoint.put(
    "network.parameters",
    [self.network.parameters.length()],
    self.network.parameters,
  )
  checkpoint.put(
    "network.dimensions",
    [self.network.dimensions.length()],
    self.network.dimensions.map(i => i.to_double()),
  )
  for
    (name, stats) in [
      ("state", self.state_stats),
      ("action", self.action_stats),
      ("context", self.context_stats),
    ] {
    checkpoint.put(name + "_mean", [stats.mean.length()], stats.mean)
    checkpoint.put(name + "_scale", [stats.scale.length()], stats.scale)
  }
  checkpoint.put("translation_invariant", [1], [
    if self.translation_invariant {
      1.0
    } else {
      0.0
    },
  ])
  checkpoint.put("root_integration_dt", [1], [
    self.root_integration_dt.unwrap_or(0),
  ])
  checkpoint
}

///|
pub fn dynamics_from_checkpoint(
  checkpoint : @artifacts.Checkpoint,
) -> Dynamics raise {
  guard checkpoint.model_kind == "residual-dynamics" else {
    fail("residual-dynamics checkpoint required")
  }
  let dimensions = checkpoint.tensor("network.dimensions").values.map(v => {
    guard v > 0 && v <= 2147483647.0 && v.to_int().to_double() == v else {
      fail("invalid network dimensions")
    }
    v.to_int()
  })
  guard dimensions.length() == 4 else {
    fail("residual network requires three dense layers")
  }
  fn stats(name : String) -> @numeric.Normalization raise {
    let mean = checkpoint.tensor(name + "_mean").values
    let scale = checkpoint.tensor(name + "_scale").values
    guard mean.length() == scale.length() && scale.all(v => v > 0) else {
      fail("invalid normalization")
    }
    { mean, scale, }
  }
  let invariant = checkpoint.tensor("translation_invariant").values[0] == 1
  let dt = checkpoint.tensor("root_integration_dt").values[0]
  let model = Dynamics::new(
    stats("state"),
    stats("action"),
    stats("context"),
    dimensions[1],
    @numeric.Rng::new(1U),
    translation_invariant=invariant,
    root_integration_dt=if dt > 0 { Some(dt) } else { None },
  )
  guard model.network.dimensions == dimensions else {
    fail("network architecture differs from normalization")
  }
  let parameters = checkpoint.tensor("network.parameters").values
  guard model.network.parameters.length() == parameters.length() else {
    fail("network parameter count differs")
  }
  restore_parameters(model.network, parameters)
  model
}

///|
fn metrics_json(metrics : DynamicsMetrics) -> Json {
  {
    "windows": metrics.windows.to_json(),
    "normalized_state_mse": metrics.mse.to_json(),
    "persistence_mse": metrics.persistence_mse.to_json(),
    "per_step_mse": metrics.per_step_mse.to_json(),
    "persistence_per_step_mse": metrics.persistence_per_step_mse.to_json(),
    "beats_persistence": (metrics.mse < metrics.persistence_mse).to_json(),
    "after_two_seconds": {
      "windows": metrics.late_windows.to_json(),
      "normalized_state_mse": metrics.late_mse.to_json(),
      "persistence_mse": metrics.late_persistence_mse.to_json(),
      "beats_persistence": (match
        (metrics.late_mse, metrics.late_persistence_mse) {
        (Some(a), Some(b)) => Some(a < b)
        _ => None
      }).to_json(),
    },
  }
}

///|
/// Full CPU dynamics runner. Uses native MoonBit JSON weights, not Torch .pt files.
pub async fn run_dynamics(
  train_path : String,
  validation_path : String,
  test_path : String,
  config_path : String,
  output : String,
) -> Unit {
  let config = @json.parse(@utf8.decode(@fs.read_file(config_path).binary()))
  let train_batch = @artifacts.load_window_batch(train_path, "train")
  let validation_batch = @artifacts.load_window_batch(
    validation_path, "validation",
  )
  let test_batch = @artifacts.load_window_batch(test_path, "test")
  train_batch.compatible(validation_batch)
  train_batch.compatible(test_batch)
  let train = windows_from_batch(train_batch)
  let validation = windows_from_batch(validation_batch)
  let test_data = windows_from_batch(test_batch)
  let floor = json_double(json_field(config, "normalization_floor"))
  let states = []
  let actions = []
  for w in train {
    states.append(w.state)
    actions.append(w.action)
  }
  let state_stats = @numeric.fit_normalization(states, floor)
  let action_stats = @numeric.fit_normalization(actions, floor)
  let context_stats = @numeric.fit_normalization(
    train.map(w => w.context),
    floor,
  )
  let fit_config : DynamicsFitConfig = {
    updates: json_int(json_field(config, "updates")),
    batch_size: json_int(json_field(config, "batch_size")),
    evaluate_every: json_int(json_field(config, "evaluate_every")),
    learning_rate: json_double(json_field(config, "learning_rate")),
    late_window_fraction: json_double_default(config, "late_window_fraction", 0),
    late_validation_weight: json_double_default(
      config, "late_validation_weight", 0,
    ),
  }
  if !@fs.exists(output) {
    @fs.mkdir(output)
  }
  let runs : Array[Json] = []
  for seed_value in json_array(json_field(config, "seeds")) {
    let started = @async.now()
    let seed = json_int(seed_value)
    let rng = @numeric.Rng::new(seed.to_uint())
    let model = Dynamics::new(
      state_stats,
      action_stats,
      context_stats,
      json_int(json_field(config, "hidden_width")),
      rng,
      translation_invariant=json_bool_default(
        config, "horizontal_translation_invariant", false,
      ),
    )
    let result = fit_dynamics(
      model, train, validation, test_data, fit_config, rng,
    )
    let training_seconds = (@async.now() - started).to_double() / 1000
    let metadata : Json = {
      "config": config,
      "seed": seed.to_json(),
      "selected_update": result.selected_update.to_json(),
      "training_batch_sha256": train_batch.digest.to_json(),
      "layout": train_batch.layout,
      "rng": "moonbit-xorshift32",
      "dtype": "float64",
      "optimizer_state_restored": false,
    }
    let selected_name = "dynamics-seed-" + seed.to_string() + ".moon.json"
    let selected_sha = @artifacts.save_checkpoint(
      output + "/" + selected_name,
      model.checkpoint(metadata),
    )
    restore_parameters(model.network, result.latest_parameters)
    let latest_name = "latest-dynamics-seed-" + seed.to_string() + ".moon.json"
    ignore(
      @artifacts.save_checkpoint(
        output + "/" + latest_name,
        model.checkpoint({
          "config": config,
          "seed": seed.to_json(),
          "selected_update": fit_config.updates.to_json(),
          "layout": train_batch.layout,
          "training_batch_sha256": train_batch.digest.to_json(),
        }),
      ),
    )
    restore_parameters(model.network, result.best_parameters)
    let restored = dynamics_from_checkpoint(
      load_learning_checkpoint(
        output + "/" + selected_name,
        "residual-dynamics",
        expected_sha256=selected_sha,
      ),
    )
    guard restored.predict(
        test_data[0].state[0],
        test_data[0].action[0],
        test_data[0].context,
      ) ==
      model.predict(
        test_data[0].state[0],
        test_data[0].action[0],
        test_data[0].context,
      ) else {
      fail("MoonBit dynamics checkpoint reload differs")
    }
    let history = result.history.map(row => {
      "update": row.update.to_json(),
      "train_loss": row.training_loss.to_json(),
      "validation_mse": row.validation.mse.to_json(),
      "selection_score": row.selection_score.to_json(),
    })
    let probe = restored.gradient_probe(validation[0])
    let metrics : Json = {
      "train": metrics_json(restored.evaluate(train)),
      "validation": metrics_json(restored.evaluate(validation)),
      "test": metrics_json(restored.evaluate(test_data)),
    }
    runs.push({
      "seed": seed.to_json(),
      "selected_update": result.selected_update.to_json(),
      "checkpoint": selected_name.to_json(),
      "checkpoint_sha256": selected_sha.to_json(),
      "latest_checkpoint": latest_name.to_json(),
      "reload_matches": true,
      "history": history.to_json(),
      "training_seconds": training_seconds.to_json(),
      "gradient_probe": {
        "passed": probe.passed.to_json(),
        "horizon": validation[0].action.length().to_json(),
        "action_gradient_norm": probe.action_gradient_norm.to_json(),
        "state_gradient_norm": probe.state_gradient_norm.to_json(),
        "analytic_directional": probe.analytic_directional.to_json(),
        "finite_difference_directional": probe.finite_difference_directional.to_json(),
        "frozen_parameter_gradients": true,
      },
      "metrics": metrics,
      "validation": metrics_json(result.validation),
      "test": metrics_json(result.test_metrics),
    })
  }
  let report : Json = {
    "format": "moonrobo.moonbit-dynamics-fit.v1",
    "config": config,
    "training_batch_sha256": train_batch.digest.to_json(),
    "horizon": train_batch.horizon.to_json(),
    "runs": runs.to_json(),
    "normalization_source": "train-windows-only",
    "selection_source": "validation-only",
    "all_passed": runs
    .all(row => {
      try! (json_field(json_field(row, "gradient_probe"), "passed") ==
      true.to_json() &&
      json_field(
        json_field(json_field(row, "metrics"), "test"),
        "beats_persistence",
      ) ==
      true.to_json())
    })
    .to_json(),
    "late_all_passed": runs
    .all(row => {
      try! ["validation", "test"].all(split => {
        try! (json_field(
          json_field(
            json_field(json_field(row, "metrics"), split),
            "after_two_seconds",
          ),
          "beats_persistence",
        ) ==
        true.to_json())
      })
    })
    .to_json(),
    "physical_execution_allowed": false,
    "numeric_backend": "pure-moonbit-float64-reverse-ad",
    "parity_status": "awaiting-python-comparison",
  }
  @fs.write_file(
    output + "/report.json",
    @utf8.encode(report.stringify(indent=2)),
    create_mode=CreateOrTruncate,
  )
}

///|
pub fn Actor::checkpoint(
  self : Actor,
  metadata : Json,
) -> @artifacts.Checkpoint raise {
  let checkpoint = @artifacts.Checkpoint::new("g1-actor", metadata)
  checkpoint.put(
    "network.parameters",
    [self.network.parameters.length()],
    self.network.parameters,
  )
  checkpoint.put(
    "network.dimensions",
    [self.network.dimensions.length()],
    self.network.dimensions.map(i => i.to_double()),
  )
  for (name, stats) in [("obs", self.obs_stats), ("goal", self.goal_stats)] {
    checkpoint.put(name + "_mean", [stats.mean.length()], stats.mean)
    checkpoint.put(name + "_scale", [stats.scale.length()], stats.scale)
  }
  checkpoint.put(
    "lower",
    [self.lower.length()],
    self.lower.map(v => if @numeric.finite(v) { v } else { 0.0 }),
  )
  checkpoint.put(
    "upper",
    [self.upper.length()],
    self.upper.map(v => if @numeric.finite(v) { v } else { 0.0 }),
  )
  checkpoint.put(
    "lower_unbounded",
    [self.lower.length()],
    self.lower.map(v => if @numeric.finite(v) { 0.0 } else { 1.0 }),
  )
  checkpoint.put(
    "upper_unbounded",
    [self.upper.length()],
    self.upper.map(v => if @numeric.finite(v) { 0.0 } else { 1.0 }),
  )
  checkpoint.put("action_delta_rad", [1], [self.action_delta_rad])
  checkpoint.put(
    "body.q_indices",
    [self.body.q_indices.length()],
    self.body.q_indices.map(v => v.to_double()),
  )
  checkpoint.put(
    "body.v_state_indices",
    [self.body.v_state_indices.length()],
    self.body.v_state_indices.map(v => v.to_double()),
  )
  checkpoint.put("body.nq", [1], [self.body.nq.to_double()])
  checkpoint
}

///|
pub fn actor_from_checkpoint(checkpoint : @artifacts.Checkpoint) -> Actor raise {
  guard checkpoint.model_kind == "g1-actor" else {
    fail("g1-actor checkpoint required")
  }
  fn integers(name : String) -> Array[Int32] raise {
    checkpoint.tensor(name).values.map(v => {
      guard v >= 0 && v <= 2147483647.0 && v.to_int().to_double() == v else {
        fail("invalid actor integer tensor")
      }
      v.to_int()
    })
  }
  fn stats(name : String) -> @numeric.Normalization raise {
    let mean = checkpoint.tensor(name + "_mean").values
    let scale = checkpoint.tensor(name + "_scale").values
    guard scale.length() == mean.length() && scale.all(v => v > 0) else {
      fail("invalid actor normalization")
    }
    { mean, scale, }
  }
  let dimensions = integers("network.dimensions")
  guard dimensions.length() == 4 else {
    fail("actor requires three dense layers")
  }
  let body : Body = {
    q_indices: integers("body.q_indices"),
    v_state_indices: integers("body.v_state_indices"),
    nq: integers("body.nq")[0],
  }
  let lower = checkpoint.tensor("lower").values
  let upper = checkpoint.tensor("upper").values
  let lower_unbounded = checkpoint.tensor("lower_unbounded").values
  let upper_unbounded = checkpoint.tensor("upper_unbounded").values
  guard lower.length() == lower_unbounded.length() &&
    upper.length() == upper_unbounded.length() else {
    fail("actor bound mask dimension differs")
  }
  for i in 0..<lower.length() {
    if lower_unbounded[i] != 0 {
      lower[i] = -1.0 / 0.0
    }
  }
  for i in 0..<upper.length() {
    if upper_unbounded[i] != 0 {
      upper[i] = 1.0 / 0.0
    }
  }
  let actor = Actor::new(
    stats("obs"),
    stats("goal"),
    lower,
    upper,
    checkpoint.tensor("action_delta_rad").values[0],
    body,
    dimensions[1],
    @numeric.Rng::new(1U),
  )
  guard actor.network.dimensions == dimensions else {
    fail("actor architecture differs from normalization")
  }
  let parameters = checkpoint.tensor("network.parameters").values
  guard parameters.length() == actor.network.parameters.length() else {
    fail("actor parameter count differs")
  }
  restore_parameters(actor.network, parameters)
  actor
}

///|
/// Include all critic buffers so weights-only warm starts preserve incoming units.
pub fn Critic::put_checkpoint(
  self : Critic,
  checkpoint : @artifacts.Checkpoint,
) -> Unit raise {
  checkpoint.put(
    "critic.parameters",
    [self.network.parameters.length()],
    self.network.parameters,
  )
  checkpoint.put(
    "critic.mean",
    [self.state_stats.mean.length()],
    self.state_stats.mean,
  )
  checkpoint.put(
    "critic.scale",
    [self.state_stats.scale.length()],
    self.state_stats.scale,
  )
  checkpoint.put(
    "critic.dimensions",
    [self.network.dimensions.length()],
    self.network.dimensions.map(i => i.to_double()),
  )
  checkpoint.put("critic.value_bound", [1], [self.value_bound])
  checkpoint.put("critic.translation_invariant", [1], [
    if self.translation_invariant {
      1.0
    } else {
      0.0
    },
  ])
}

///|
pub fn critic_from_actor_checkpoint(
  checkpoint : @artifacts.Checkpoint,
  n_goal : Int32,
  n_context : Int32,
  translation_invariant? : Bool,
) -> Critic raise {
  let mean = checkpoint.tensor("critic.mean").values
  let scale = checkpoint.tensor("critic.scale").values
  guard mean.length() == scale.length() && scale.all(v => v > 0) else {
    fail("invalid critic normalization")
  }
  let value_bound = checkpoint.tensor("critic.value_bound").values[0]
  guard value_bound >= 3 else { fail("invalid critic value bound") }
  let prior_encoding = checkpoint.tensor("critic.translation_invariant").values[0] !=
    0
  let critic = Critic::new(
    { mean, scale, },
    n_goal,
    n_context,
    1 - 3 / value_bound,
    @numeric.Rng::new(1U),
    translation_invariant=translation_invariant.unwrap_or(prior_encoding),
  )
  let dimensions = checkpoint.tensor("critic.dimensions").values
  guard critic.network.dimensions.map(i => i.to_double()) == dimensions else {
    fail("critic architecture differs")
  }
  let parameters = checkpoint.tensor("critic.parameters").values
  guard parameters.length() == critic.network.parameters.length() else {
    fail("critic parameters differ")
  }
  restore_parameters(critic.network, parameters)
  critic.enforce_input_encoding()
  critic
}
