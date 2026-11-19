///|
fn field(value : Json, key : String) -> Json raise {
  guard value is Object(fields) && fields.get(key) is Some(result) else {
    fail("missing comparison field: " + key)
  }
  result
}

///|
/// Same held-out arrays and the initial model's scale for every checkpoint.
pub fn common_metrics(
  model : @training.Dynamics,
  windows : Array[@training.Window],
  scale : Array[Double],
) -> Json raise {
  guard !windows.is_empty() &&
    !scale.is_empty() &&
    scale.all(v => v > 0 && @numeric.finite(v)) else {
    fail("nonempty common-scale evaluation required")
  }
  let mut errors = 0.0
  let mut persistence = 0.0
  let mut late = 0.0
  let mut elements = 0
  let mut late_elements = 0
  let mut late_windows = 0
  let horizon = windows[0].action.length()
  guard horizon > 0 else { fail("empty common-scale horizon") }
  for window in windows {
    guard window.action.length() == horizon &&
      window.target.length() == horizon &&
      !window.state.is_empty() else {
      fail("common-scale horizons differ")
    }
    let initial = window.state[0]
    guard initial.length() == scale.length() else {
      fail("common-scale initial shape differs")
    }
    let mut state = initial
    if window.start_time_s >= 2 {
      late_windows += 1
    }
    for t in 0..<horizon {
      state = model.predict(state, window.action[t], window.context)
      guard state.length() == scale.length() &&
        window.target[t].length() == scale.length() else {
        fail("common-scale target shape differs")
      }
      for j in 0..<scale.length() {
        let delta = (state[j] - window.target[t][j]) / scale[j]
        let baseline = (initial[j] - window.target[t][j]) / scale[j]
        guard @numeric.finite(delta) && @numeric.finite(baseline) else {
          fail("nonfinite common-scale prediction")
        }
        errors += delta * delta
        persistence += baseline * baseline
        elements += 1
        if window.start_time_s >= 2 {
          late += delta * delta
          late_elements += 1
        }
      }
    }
  }
  let late_mse : Double? = if late_elements > 0 {
    Some(late / late_elements.to_double())
  } else {
    None
  }
  {
    "windows": Json(windows.length()),
    "normalized_state_mse": Json(errors / elements.to_double()),
    "persistence_mse": Json(persistence / elements.to_double()),
    "after_two_seconds": {
      "windows": Json(late_windows),
      "normalized_state_mse": match late_mse {
        Some(value) => Json(value)
        None => Json::null()
      },
    },
  }
}

///|
pub async fn run(
  initial : String,
  corrected : String,
  validation : String,
  test_path : String,
  output : String,
) -> Json {
  let batches = [
    @artifacts.load_window_batch(validation, "validation"),
    @artifacts.load_window_batch(test_path, "test"),
  ]
  batches[0].compatible(batches[1], require_dataset_id=false)
  let initial_checkpoint = @training.load_learning_checkpoint(
    initial, "residual-dynamics",
  )
  let initial_model = @training.dynamics_from_checkpoint(initial_checkpoint)
  let layout = field(initial_checkpoint.metadata, "layout")
  let paths = [initial]
  for i in 0..<3 {
    let native = corrected + "/dynamics-seed-\{i}.moon.json"
    paths.push(
      if @fs.exists(native) {
        native
      } else {
        corrected + "/dynamics-seed-\{i}.pt"
      },
    )
  }
  let rows : Array[Json] = []
  for i, path in paths {
    let checkpoint = @training.load_learning_checkpoint(
      path, "residual-dynamics",
    )
    let model_layout = field(checkpoint.metadata, "layout")
    for
      key in [
        "model_ref", "dt_s", "state_axes", "action_axes", "context_axes", "frame_convention",
      ] {
      for batch in batches {
        guard field(model_layout, key) == field(layout, key) &&
          field(model_layout, key) == field(batch.layout, key) else {
          fail("incompatible common-scale prediction inputs: " + key)
        }
      }
    }
    let model = @training.dynamics_from_checkpoint(checkpoint)
    let metrics = batches.map(batch => {
      common_metrics(
        model,
        @training.windows_from_batch(batch),
        initial_model.state_stats.scale,
      )
    })
    rows.push({
      "model": Json(if i == 0 { "initial" } else { "refitted-\{i - 1}" }),
      "checkpoint_sha256": Json(@artifacts.sha256(@fs.read_file(path).binary())),
      "metrics": { "validation": metrics[0], "test": metrics[1] },
    })
  }
  let report : Json = {
    "format": "moonrobo.g1-common-scale-dynamics.v1",
    "metric_scale": "initial model train-only state scale",
    "inputs": {
      "validation": Json(batches[0].digest),
      "test": Json(batches[1].digest),
    },
    "rows": Json(rows),
    "scope": "Post-selection prediction diagnostics on identical held-out arrays and one shared scale; no physical-gradient or control qualification.",
  }
  @fs.write_file(
    output,
    @utf8.encode(report.stringify(indent=2)),
    create_mode=CreateOrTruncate,
  )
  report
}
