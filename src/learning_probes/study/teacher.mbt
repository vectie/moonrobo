///|
fn temporal_torch_delta(
  value : @artifacts.TorchValue,
  actor : @temporal.TemporalPolicy,
) -> Array[Double] raise {
  let parameters : Array[Double] = []
  for
    (prefix, dimensions) in [
      ("base.net.", actor.base.network.dimensions),
      ("adapter.", actor.temporal.adapter.dimensions),
    ] {
    for i in 0..<(dimensions.length() - 1) {
      let layer = (i * 2).to_string()
      let w = value.field(prefix + layer + ".weight").tensor()
      let b = value.field(prefix + layer + ".bias").tensor()
      if w.shape != [dimensions[i + 1], dimensions[i]] ||
        b.shape != [dimensions[i + 1]] {
        fail("temporal direction tensor shape differs")
      }
      parameters.append(w.values)
      parameters.append(b.values)
    }
  }
  if parameters.length() != actor.parameters().length() {
    fail("temporal direction parameter count differs")
  }
  parameters
}

///|
/// Directory traversal and digest binding from teacher_step_verification.py.
pub async fn run_teacher_verification(options : Map[String, String]) -> Unit {
  let rows : Array[Json] = []
  for variant in ["frame", "preview"] {
    let report = read(
      option(options, "--study") + "/" + variant + "/policy/report.json",
    )
    for result in arr(report, "runs") {
      if int(result, "selected_update") != 1 {
        continue
      }
      let seed = int(result, "seed")
      let incoming = checkpoint_path(
        option(options, "--incoming") + "/" + variant + "/policy",
        "actor-seed-\{seed}",
      )
      let direction_path = checkpoint_path(
        option(options, "--probe") + "/" + variant,
        "directions-seed-\{seed}",
      )
      let initial = @temporal.load_temporal(incoming)
      let selected = @temporal.load_temporal(
        option(options, "--study") +
        "/" +
        variant +
        "/policy/" +
        str(result, "checkpoint"),
      )
      for
        (a, b) in [
          (initial.base.obs_stats, selected.base.obs_stats),
          (initial.base.goal_stats, selected.base.goal_stats),
        ] {
        if a.mean != b.mean || a.scale != b.scale {
          fail("teacher update changed normalization buffers")
        }
      }
      if initial.base.lower != selected.base.lower ||
        initial.base.upper != selected.base.upper ||
        initial.base.action_delta_rad != selected.base.action_delta_rad {
        fail("teacher update changed action buffers")
      }
      let delta = if direction_path.has_suffix(".pt") {
        let saved = @artifacts.load_torch_checkpoint(direction_path)
        if saved.field("actor_sha256").plain_json() !=
          digest(incoming).to_json() {
          fail("teacher direction actor differs")
        }
        temporal_torch_delta(
          saved.field("directions").field("draw-0-tail-True-teacher"),
          initial,
        )
      } else {
        let saved = @artifacts.load_checkpoint(
          direction_path, "parameter-direction-collection",
        )
        if str(saved.metadata, "actor_sha256") != digest(incoming) {
          fail("teacher direction actor differs")
        }
        saved.tensor("draw-0-tail-true-teacher").values
      }
      let predicted = @probes.scaled_actor(initial.parameters(), delta, 1)
      if incoming.has_suffix(".pt") {
        for i, v in predicted {
          predicted[i] = v.to_float().to_double()
        }
      }
      let target = selected.parameters()
      if predicted.length() != target.length() {
        fail("selected teacher parameter count differs")
      }
      let zero = Array::make(predicted.length(), 0.0)
      let (maximum, exact) = @probes.verify_teacher_step(
        predicted, zero, target,
      )
      rows.push({
        "variant": variant,
        "seed": seed,
        "maximum_parameter_error": maximum,
        "bitwise_equal": exact,
        "direction_sha256": digest(direction_path),
      })
    }
  }
  write(option(options, "--output"), {
    "format": "moonrobo.g1-teacher-first-step-verification.v1",
    "rows": rows,
  })
}
