///|
fn field(value : Json, key : String) -> Json raise {
  @ref.json_field(value, key)
}

///|
fn number(value : Json, key : String) -> Double raise {
  @json.from_json(field(value, key))
}

///|
fn integer(value : Json, key : String) -> Int32 raise {
  @json.from_json(field(value, key))
}

///|
fn text(value : Json, key : String) -> String raise {
  @json.from_json(field(value, key))
}

///|
fn rows(value : Json, key : String) -> Array[Json] raise {
  @json.from_json(field(value, key))
}

///|
async fn digest(path : String) -> String {
  @artifacts.sha256(@fs.read_file(path).binary())
}

///|
fn child(root : String, path : String) -> String {
  if path.has_prefix("/") {
    path
  } else {
    root + "/" + path
  }
}

///|
async fn checkpoint_path(stem : String) -> String {
  for suffix in [".moon.json", ".json", ".pt"] {
    if @fs.exists(stem + suffix) {
      return stem + suffix
    }
  }
  fail("reference checkpoint absent: " + stem)
}

///|
fn model_digest(model : @training.Dynamics) -> String {
  let data : Json = {
    "state_mean": model.state_stats.mean.to_json(),
    "state_scale": model.state_stats.scale.to_json(),
    "action_mean": model.action_stats.mean.to_json(),
    "action_scale": model.action_stats.scale.to_json(),
    "context_mean": model.context_stats.mean.to_json(),
    "context_scale": model.context_stats.scale.to_json(),
    "dimensions": model.network.dimensions.to_json(),
    "parameters": model.network.parameters.to_json(),
  }
  @artifacts.sha256(@utf8.encode(data.stringify()))
}

///|
fn value_digest(value : @ref.ReferenceValue) -> String {
  @artifacts.sha256(@utf8.encode(value.to_json().stringify()))
}

///|
pub async fn archived_batch(
  folder : String,
  records : Array[Json],
  actor : @ref.ReferenceActor,
  schedule : @ref.ReferenceSchedule,
  gamma : Double,
) -> @ref.CollectedBatch {
  guard !records.is_empty() else { fail("missing source physical records") }
  let result = @ref.restore_record_group(
    folder, records, actor, schedule, gamma,
  )
  guard result.points.length() ==
    records.fold(init=0, fn(total, row) { total + integer(row, "steps") }) else {
    fail("recorded episode lengths differ from archived steps")
  }
  result
}

///|
fn raw_means(
  actor : @ref.ReferenceActor,
  points : Array[@ref.LearningPoint],
  schedule : @ref.ReferenceSchedule,
) -> Array[Array[Double]] {
  points.map(fn(point) {
    let command = schedule.command(point.clip, point.step, actor.future_length)
    actor.latent_mean(
      point.history,
      command.current,
      command.future,
      command.valid,
    )
  })
}

///|
fn rms_difference(a : Array[Array[Double]], b : Array[Array[Double]]) -> Double {
  guard a.length() == b.length() && !a.is_empty() else {
    abort("mean calibration shape mismatch")
  }
  let mut sum = 0.0
  let mut count = 0
  for i, row in a {
    guard row.length() == b[i].length() else {
      abort("mean calibration width mismatch")
    }
    for j, x in row {
      let d = x - b[i][j]
      sum += d * d
      count += 1
    }
  }
  (sum / count.to_double()).sqrt()
}

///|
fn apply_direction(
  actor : @ref.ReferenceActor,
  base : Array[Double],
  direction : Array[Double],
  amount : Double,
) -> Unit {
  guard base.length() == direction.length() else {
    abort("parameter direction shape mismatch")
  }
  actor.set_parameters(
    Array::makei(base.length(), fn(i) { base[i] + amount * direction[i] }),
  )
}

///|
async fn load_value(
  source : String,
  seed : Int32,
  source_report : Json,
) -> (@ref.ReferenceValue, Json) {
  let path = checkpoint_path(
    source + "/model-based/seed-" + seed.to_string() + "/policy/value-cycle-1",
  )
  let value = @ref.load_reference_value(path, clips=9)
  let run = @ref.select_run(source_report, "model-based", seed)
  let cycles = rows(run, "cycles")
  guard !cycles.is_empty() else {
    fail("missing initial calibrated critic cycle")
  }
  let expected = text(field(cycles[0], "critic"), "state_sha256")
  let actual = @ref.checkpoint_state_digest(path, "value")
  guard actual == expected else { fail("critic differs from common fit") }
  (
    value,
    {
      "file": path.to_json(),
      "sha256": digest(path).to_json(),
      "state_sha256": actual.to_json(),
    },
  )
}

///|
fn objective(
  model : @training.Dynamics,
  actor : @ref.ReferenceActor,
  value : @ref.ReferenceValue?,
  points : Array[@ref.LearningPoint],
  geometry : @balance.Kinematics,
  schedule : @ref.ReferenceSchedule,
  learning : Json,
) -> (Double, Int32) raise {
  let tape = @numeric.Tape::new()
  let (value, active) = @ref.imagined_objective(
    tape,
    model,
    actor,
    tape.vector(actor.parameters()),
    value,
    points,
    geometry,
    schedule,
    integer(learning, "imagination_horizon"),
    number(learning, "gamma"),
    feedback_gradient=if @ref.config_default(
        learning, "actor_feedback_gradient", "full",
      ) ==
      "stop-policy-inputs" {
      StopPolicyInputs
    } else {
      Full
    },
    critic_tail=true,
  )
  (value.value, active)
}

///|
fn first_points(batch : @ref.CollectedBatch) -> Array[@ref.LearningPoint] {
  let result : Array[@ref.LearningPoint] = []
  let mut index = 0
  for n in batch.episode_lengths {
    guard n > 0 else { abort("empty physical episode") }
    result.push(batch.points[index])
    index += n
  }
  result
}

///|
fn returns_by_episode(
  batch : @ref.CollectedBatch,
  clips : Array[Int32],
  gamma : Double,
) -> Array[Json] {
  guard batch.episode_lengths.length() == clips.length() else {
    abort("probe returns clip alignment differs")
  }
  let result : Array[Json] = []
  let mut start = 0
  for i, n in batch.episode_lengths {
    let rewards = batch.reward[start:start + n].to_owned()
    let r = @ref.discounted_returns(rewards, gamma, 32)
    result.push({
      "clip_index": clips[i].to_json(),
      "prefix_return": r.prefix_return.to_json(),
      "full_return": r.full_return.to_json(),
    })
    start += n
  }
  result
}

///|
pub fn prediction_metrics(
  model : @training.Dynamics,
  batch : @ref.CollectedBatch,
) -> Array[Json] raise {
  [8, 32].map(fn(horizon) {
    let sums = [0.0, 0.0, 0.0, 0.0]
    let mut count = 0
    let mut start = 0
    for length in batch.episode_lengths {
      for offset = 0; offset <= length - horizon; offset = offset + horizon / 2 {
        let first = start + offset
        let initial = batch.points[first].state
        let mut state = initial
        for t in 0..<horizon {
          state = model.predict(
            state,
            batch.actions[first + t],
            batch.points[first].context,
          )
          let truth = batch.next_states[first + t]
          for j in 0..<state.length() {
            let d = (state[j] - truth[j]) / model.state_stats.scale[j]
            let p = (initial[j] - truth[j]) / model.state_stats.scale[j]
            sums[0] += d * d / (horizon * state.length()).to_double()
            sums[1] += p * p / (horizon * state.length()).to_double()
          }
          for j in 0..<3 {
            let p = state[j] - truth[j]
            let v = state[36 + j] - truth[36 + j]
            sums[2] += p * p / (horizon * 3).to_double()
            sums[3] += v * v / (horizon * 3).to_double()
          }
        }
        count += 1
      }
      start += length
    }
    guard count > 0 else { fail("missing diagnostic windows") }
    (
      {
        "horizon": horizon.to_json(),
        "windows": count.to_json(),
        "normalized_state_mse": (sums[0] / count.to_double()).to_json(),
        "persistence_mse": (sums[1] / count.to_double()).to_json(),
        "root_position_component_rmse_m": (sums[2] / count.to_double())
        .sqrt()
        .to_json(),
        "root_linear_velocity_component_rmse_m_per_s": (sums[3] /
        count.to_double())
        .sqrt()
        .to_json(),
      } : Json)
  })
}
