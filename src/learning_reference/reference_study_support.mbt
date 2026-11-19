///|
pub fn config_default(
  config : Json,
  key : String,
  fallback : Json,
) -> Json raise {
  json_fields(config).get(key).unwrap_or(fallback)
}

///|
pub fn sample_indices_digest(samples : Array[Array[Int32]]) -> String {
  let bytes : Array[Byte] = []
  for row in samples {
    for index in row {
      let value = index.to_int64()
      for i in 0..<8 {
        bytes.push(((value >> (i * 8)) & 255L).to_int().to_byte())
      }
    }
  }
  @artifacts.sha256(Bytes::from_array(bytes))
}

///|
pub fn seconds_steps(values : Json, dt : Double) -> Array[Int32] raise {
  json_array(values).map(value => @math.round(json_number(value) / dt).to_int())
}

///|
pub fn settings_for_method(
  config : Json,
  method_name : String,
) -> ReferenceLearningConfig raise {
  let prefix = [
    "prefix-only", "replay-prefix", "replay-prefix-extended", "replay-prefix-anchor",
  ].contains(method_name)
  let replay = [
    "replay-prefix", "replay-prefix-extended", "replay-prefix-anchor",
  ].contains(method_name)
  let gradient = json_text(
    config_default(config, "actor_feedback_gradient", "full".to_json()),
  )
  guard gradient == "full" || gradient == "stop-policy-inputs" else {
    fail("unknown policy-input gradient route")
  }
  {
    gamma: json_number(json_field(config, "gamma")),
    gae_lambda: json_number(json_field(config, "gae_lambda")),
    raw_action_std: json_number(json_field(config, "raw_action_std")),
    imagination_horizon: json_integer(json_field(config, "imagination_horizon")),
    critic_updates: json_integer(json_field(config, "critic_updates_per_cycle")),
    critic_batch_size: json_integer(json_field(config, "critic_batch_size")),
    model_updates: json_integer(json_field(config, "model_updates_per_cycle")),
    model_batch_size: json_integer(json_field(config, "model_batch_size")),
    actor_steps: json_integer(
      json_field(config, "maximum_actor_steps_per_cycle"),
    ),
    actor_batch_size: json_integer(json_field(config, "actor_batch_size")),
    ppo_epochs: json_integer(json_field(config, "ppo_epochs")),
    ppo_minibatch_size: json_integer(json_field(config, "ppo_minibatch_size")),
    ppo_clip: json_number(json_field(config, "ppo_clip")),
    ppo_target_kl: json_number(json_field(config, "ppo_target_kl")),
    actor_trajectory_states: replay,
    actor_critic_tail: !prefix,
    feedback_gradient: if gradient == "full" {
      Full
    } else {
      StopPolicyInputs
    },
  }
}

///|
pub fn model_diagnostics(
  model : @training.Dynamics,
  batch : CollectedBatch,
) -> Array[Json] {
  [8, 32].map(horizon => {
    let windows : Array[@training.Window] = []
    let mut start = 0
    for length in batch.episode_lengths {
      for offset = 0
          offset <= length - horizon
          offset = offset + (horizon / 2).max(1) {
        let first = start + offset
        windows.push({
          state: batch.points[first:first + horizon].map(point => point.state),
          action: batch.actions[first:first + horizon].to_owned(),
          target: batch.next_states[first:first + horizon].to_owned(),
          context: batch.points[first].context,
          start_time_s: 0.0,
        })
      }
      start += length
    }
    if windows.is_empty() {
      (
        {
          "horizon": horizon,
          "windows": 0,
          "normalized_mse": Json::null(),
          "persistence_mse": Json::null(),
        } : Json)
    } else {
      let metrics = model.evaluate(windows)
      (
        {
          "horizon": horizon,
          "windows": windows.length(),
          "normalized_mse": metrics.mse,
          "persistence_mse": metrics.persistence_mse,
        } : Json)
    }
  })
}

///|
pub fn inherited_record(record : Json, source : String) -> Json raise {
  let record = json_fields(record)
  record["file"] = path_child(source, json_text(record["file"])).to_json()
  let behavior = json_fields(record["behavior"])
  behavior["checkpoint"] = path_child(source, json_text(behavior["checkpoint"])).to_json()
  if behavior.get("direction_file") is Some(file) {
    behavior["direction_file"] = path_child(source, json_text(file)).to_json()
  }
  record["behavior"] = behavior.to_json()
  record.to_json()
}

///|
fn reused_run(run : Json, source : String) -> Json raise {
  let result = json_fields(run)
  let rewrite = (metadata : Json) => {
    let fields = json_fields(metadata)
    fields["checkpoint"] = path_child(source, json_text(fields["checkpoint"])).to_json()
    fields.to_json()
  }
  result["checkpoint"] = rewrite(result["checkpoint"])
  result["cycles"] = json_array(result["cycles"])
    .map(cycle => {
      let fields = json_fields(cycle)
      fields["checkpoint"] = rewrite(fields["checkpoint"])
      fields.to_json()
    })
    .to_json()
  result["reused_from_study"] = source.to_json()
  result.to_json()
}

///|
pub async fn restore_record_group(
  folder : String,
  records : Array[Json],
  actor : ReferenceActor,
  schedule : ReferenceSchedule,
  gamma : Double,
) -> CollectedBatch {
  let batches : Array[CollectedBatch] = []
  for record in records {
    let context : Array[Double] = @json.from_json(json_field(record, "context"))
    batches.push(
      restore_python_collection(
        path_child(folder, json_text(json_field(record, "file"))),
        json_text(json_field(record, "sha256")),
        json_integer(json_field(record, "clip_index")),
        json_integer(json_field(record, "origin_step")),
        context,
        actor,
        schedule,
        gamma,
      ),
    )
  }
  join_batches(batches)
}

///|
pub fn append_replay(
  replay : ReferenceModelReplay,
  batch : CollectedBatch,
) -> Unit {
  let episodes : Array[LearningEpisode] = []
  let mut start = 0
  for length in batch.episode_lengths {
    episodes.push({
      state: batch.points[start:start + length].map(point => point.state),
      action: batch.actions[start:start + length].to_owned(),
      next_state: batch.next_states[start:start + length].to_owned(),
      context: batch.points[start].context,
    })
    start += length
  }
  replay.append(episodes)
}

///|
pub fn value_at_point(
  value : ReferenceValue,
  point : LearningPoint,
  schedule : ReferenceSchedule,
) -> Double {
  let clip = schedule.clips[point.clip]
  value.forward(
    point.state,
    point.history,
    clip.goals[point.step],
    point.actual_features,
    point.reference_features,
    point.context,
    point.clip,
    point.step,
    schedule.length - point.step,
    clip.positions[point.step][0],
    clip.quaternions[point.step],
  )
}

///|
pub fn select_run(
  report : Json,
  method_name : String,
  seed : Int32,
) -> Json raise {
  for run in json_array(json_field(report, "runs")) {
    if json_text(json_field(run, "method")) == method_name &&
      json_integer(json_field(run, "seed")) == seed {
      return run
    }
  }
  fail("matching source study method and seed absent")
}

///|
pub async fn verify_reconstructed_cycle(
  actor : ReferenceActor,
  model : @training.Dynamics,
  value : ReferenceValue,
  old_cycle : Json,
  source : String,
) -> Json {
  let checkpoint = json_field(old_cycle, "checkpoint")
  let path = path_child(source, json_text(json_field(checkpoint, "checkpoint")))
  let (previous_actor, _) = load_reference_actor(
    path,
    expected_sha256=json_text(json_field(checkpoint, "sha256")),
  )
  let cycle = json_integer(json_field(old_cycle, "cycle"))
  let parent = path[:path.length() - path_name(path).length()].to_owned()
  let model_file = if @fs.exists(parent + "dynamics-cycle-\{cycle}.json") {
    parent + "dynamics-cycle-\{cycle}.json"
  } else {
    parent + "dynamics-cycle-\{cycle}.pt"
  }
  let value_file = if @fs.exists(parent + "value-cycle-\{cycle}.json") {
    parent + "value-cycle-\{cycle}.json"
  } else {
    parent + "value-cycle-\{cycle}.pt"
  }
  let (previous_model, _) = load_reference_dynamics(model_file)
  let previous_value = load_reference_value(value_file, clips=value.clips)
  guard actor.to_json() == previous_actor.to_json() else {
    fail("reconstructed actor differs at cycle \{cycle}")
  }
  guard model.network.parameters == previous_model.network.parameters else {
    fail("reconstructed model differs at cycle \{cycle}")
  }
  for
    (current, previous) in [
      (model.state_stats, previous_model.state_stats),
      (model.action_stats, previous_model.action_stats),
      (model.context_stats, previous_model.context_stats),
    ] {
    guard current.mean == previous.mean && current.scale == previous.scale else {
      fail("reconstructed model normalization differs at cycle \{cycle}")
    }
  }
  guard value.to_json() == previous_value.to_json() else {
    fail("reconstructed value differs at cycle \{cycle}")
  }
  {
    "cycle": cycle,
    "actor_state_sha256": state_digest(actor),
    "model_state_sha256": @artifacts.sha256(
      @utf8.encode(model.checkpoint(Json::null()).to_json().stringify()),
    ),
    "value_state_sha256": @artifacts.sha256(
      @utf8.encode(value.to_json().stringify()),
    ),
    "all_tensors_identical": true,
  }
}
