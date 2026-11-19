///|
pub(all) struct PredictionMetrics {
  horizon : Int32
  windows : Int32
  last_window_offset : Int32?
  normalized_state_mse : Double?
  persistence_mse : Double?
  root_position_component_rmse_m : Double?
  joint_rmse_rad : Double?
  root_velocity_component_rmse_m_per_s : Double?
  root_orientation_rmse_rad : Double?
} derive(Debug, ToJson)

///|
/// All windows have equal weight. Operates within one episode, never across resets.
pub fn prediction_metrics(
  state : Array[Array[Double]],
  action : Array[Array[Double]],
  target : Array[Array[Double]],
  context : Array[Double],
  scale : Array[Double],
  horizons : Array[Int32],
  predict : (Array[Double], Array[Double], Array[Double]) -> Array[Double],
) -> Array[PredictionMetrics] {
  horizons.map(horizon => {
    let starts = window_starts(state.length(), horizon)
    let sums = Array::make(6, 0.0)
    for start in starts {
      let mut current = state[start]
      for t in 0..<horizon {
        current = predict(current, action[start + t], context)
        let truth = target[start + t]
        for i in 0..<current.length() {
          let error = (current[i] - truth[i]) / scale[i]
          let baseline = (state[start][i] - truth[i]) / scale[i]
          sums[0] += error * error / current.length().to_double()
          sums[1] += baseline * baseline / current.length().to_double()
        }
        for (slot, offset, count) in [(2, 0, 3), (3, 7, 29), (4, 36, 3)] {
          for i in offset..<(offset + count) {
            let error = current[i] - truth[i]
            sums[slot] += error * error / count.to_double()
          }
        }
        let cosine = dot(
          unit(current[3:7].to_owned()),
          unit(truth[3:7].to_owned()),
        ).abs()
        let angle = 2.0 * @math.acos(clamp(cosine, 0.0, 1.0))
        sums[5] += angle * angle
      }
    }
    let n = starts.length()
    let average = (i : Int32) => {
      if n == 0 {
        None
      } else {
        Some(sums[i] / (n * horizon).to_double())
      }
    }
    (
      {
        horizon,
        windows: n,
        last_window_offset: if n == 0 {
          None
        } else {
          Some(starts[n - 1])
        },
        normalized_state_mse: average(0),
        persistence_mse: average(1),
        root_position_component_rmse_m: average(2).map(x => x.sqrt()),
        joint_rmse_rad: average(3).map(x => x.sqrt()),
        root_velocity_component_rmse_m_per_s: average(4).map(x => x.sqrt()),
        root_orientation_rmse_rad: average(5).map(x => x.sqrt()),
      } : PredictionMetrics)
  })
}

///|
pub fn json_array(value : Json) -> Array[Json] raise {
  match value {
    Array(values) => values
    _ => fail("expected JSON array")
  }
}

///|
pub fn baseline_record_ids(
  report : Json,
  method_name : String,
) -> Array[String] raise {
  let ids : Map[String, Bool] = Map([])
  for record in json_array(json_field(report, "physical_records")) {
    if ["initial", "common-first-collection", "model-diagnostic"].contains(
        json_text(json_field(record, "role")),
      ) {
      ids[json_text(json_field(record, "episode_id"))] = true
    }
  }
  for run in json_array(json_field(report, "runs")) {
    if json_text(json_field(run, "method")) != method_name {
      continue
    }
    for trial in json_array(json_field(run, "trials")) {
      ids[json_text(json_field(trial, "episode_id"))] = true
    }
    for cycle in json_array(json_field(run, "cycles")) {
      for id in json_array(json_field(cycle, "training_episode_ids")) {
        ids[json_text(id)] = true
      }
    }
  }
  ids.keys().collect()
}

///|
pub fn comparison_baseline(
  report : Json,
  method_name : String,
  seed : Int32,
) -> (Json, String) raise {
  let config = json_field(report, "config")
  let baseline_method = match config {
    Object(fields) =>
      match fields.get("reused_baseline_method") {
        Some(value) => json_text(value)
        None => "prefix-only"
      }
    _ => fail("comparison configuration")
  }
  if method_name == baseline_method {
    return (json_field(report, "initial"), "Shared zero-output prior")
  }
  for run in json_array(json_field(report, "runs")) {
    if json_text(json_field(run, "method")) != baseline_method {
      continue
    }
    guard json_field(run, "seed") is Number(value, ..) else {
      fail("comparison seed")
    }
    if value != seed.to_double() {
      continue
    }
    let role = if baseline_method == "prefix-only" {
      "Fixed reset-only trained policy with the same training seed"
    } else if baseline_method == "replay-prefix-extended" {
      "Fixed six-cycle recent-FIFO trained policy with the same training seed"
    } else {
      "Fixed \{json_array(json_field(run, "cycles")).length()}-cycle trajectory-state trained policy with the same training seed"
    }
    return (run, role)
  }
  fail("matching baseline method and seed absent")
}
