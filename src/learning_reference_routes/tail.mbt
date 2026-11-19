///|
/// Compare inherited full-tail directions to newly differentiated fixed-H32 prefix-only directions in real physics.
pub async fn run_tail_directions(
  model_source : String,
  library : String,
  scene : String,
  output : String,
) -> Unit {
  let model_source = @fs.realpath(model_source)
  let output = @fs.realpath(output)
  let started = @async.now()
  let config = @artifacts.load_json(output + "/config.json")
  verify_hash(
    model_source + "/report.json",
    text(config, "model_source_report_sha256"),
  )
  let previous = @artifacts.load_json(model_source + "/report.json")
  let source = @fs.realpath(text(previous, "source_study"))
  verify_hash(source + "/report.json", text(config, "source_report_sha256"))
  let source_report = @artifacts.load_json(source + "/report.json")
  let learning = field(source_report, "config")
  let incoming = initial_actor_path(output)
  verify_hash(incoming, text(source_report, "initialization_sha256"))
  let base_hash = digest(incoming)
  let (actor, metadata) = @reference.load_reference_actor(incoming)
  let geometry = @reference.kinematics_from_spec(metadata.kinematics)
  let base = actor.parameters()
  let references_path = @fs.realpath(text(previous, "references"))
  let (_, references) = @reference.load_references(references_path)
  verify_hash(
    references_path + "/manifest.json",
    text(previous, "reference_manifest_sha256"),
  )
  let schedule = @reference.ReferenceSchedule::new(
    references.map(r => try! r.clip()),
    geometry,
    [0],
    0.02,
  )
  let runtime = @native_physics.Runtime::open(library, scene)
  let baseline_returns = array(previous, "baseline_returns")
  let records : Array[Json] = []
  for record in array(previous, "physical_records") {
    records.push(@reference.inherited_record(record, model_source))
  }
  let reused_count = records.length()
  let rows : Array[Json] = []
  let clip_ids : Array[Int32] = @json.from_json(
    field(config, "probe_clip_indices"),
  )
  let amplitudes : Array[Double] = @json.from_json(
    field(config, "logit_rms_steps"),
  )
  let signs : Array[Double] = @json.from_json(field(config, "probe_signs"))
  for old in array(previous, "runs") {
    let reused = merge(old, {
      "tail_mode": "with-tail",
      "new_model_updates": 0,
      "checkpoint": child(model_source, text(old, "checkpoint")).to_json(),
      "direction_file": child(model_source, text(old, "direction_file")).to_json(),
      "physics_reused": true,
    })
    rows.push(reused)
    let seed = integer(old, "seed")
    let variant = text(old, "variant")
    let model_path = child(model_source, text(old, "checkpoint"))
    verify_hash(model_path, text(old, "checkpoint_sha256"))
    let (model, model_meta) = @reference.load_reference_dynamics(model_path)
    let frozen_model = model.network.parameters.copy()
    let training_records = array(old, "training_records")
    guard field(model_meta, "training_episode_ids") ==
      training_records.map(r => try! field(r, "episode_id")).to_json() else {
      fail("model training data differ from common collection")
    }
    actor.set_parameters(base)
    let training = @reference.restore_record_group(
      source,
      training_records,
      actor,
      schedule,
      number(learning, "gamma"),
    )
    let starts : Array[Int32] = []
    let mut first = 0
    for length in training.episode_lengths {
      starts.push(first)
      first += length
    }
    let first_points = starts.map(i => training.points[i])
    let probes = clip_ids.map(i => first_points[i])
    let (_, _, gradient) = objective(
      model,
      actor,
      first_points,
      geometry,
      schedule,
      learning,
      @reference.Full,
      true,
    )
    let gradient_norm = norm(gradient)
    guard @numeric.finite(gradient_norm) && gradient_norm > 0 else {
      fail("invalid prefix direction")
    }
    let direction = gradient.map(v => v / gradient_norm)
    let initial_means = raw_means(actor, training.points, schedule)
    actor.set_parameters(
      Array::makei(base.length(), i => base[i] + 0.001 * direction[i]),
    )
    let response = rms_difference(
        raw_means(actor, training.points, schedule),
        initial_means,
      ) /
      0.001
    actor.set_parameters(base)
    guard @numeric.finite(response) && response >= 0.00000001 else {
      fail("uncalibrated prefix direction")
    }
    let direction_file = output +
      "/direction-" +
      variant +
      "-prefix-only-seed-" +
      seed.to_string() +
      ".moon.json"
    let direction_sha = save_direction(
      direction_file,
      actor,
      direction,
      base_hash,
      {
        "gradient_norm": gradient_norm.to_json(),
        "calibration_response": response.to_json(),
      },
    )
    let (predicted_before, _, _) = objective(
      model,
      actor,
      probes,
      geometry,
      schedule,
      learning,
      @reference.Full,
      false,
    )
    let outcomes : Array[Json] = []
    for amplitude in amplitudes {
      for sign in signs {
        let amount = sign * amplitude / response
        actor.set_parameters(
          Array::makei(base.length(), i => base[i] + amount * direction[i]),
        )
        let achieved = rms_difference(
          raw_means(actor, training.points, schedule),
          initial_means,
        )
        let (predicted_after, _, _) = objective(
          model,
          actor,
          probes,
          geometry,
          schedule,
          learning,
          @reference.Full,
          false,
        )
        let behavior : Json = {
          "checkpoint": incoming.to_json(),
          "sha256": base_hash.to_json(),
          "direction_file": direction_file.to_json(),
          "direction_sha256": direction_sha.to_json(),
          "coefficient": amount.to_json(),
        }
        let role = variant +
          "-prefix-only-amp-" +
          amplitude.to_string() +
          "-sign-" +
          sign.to_string()
        let group = @reference.physical_group(
          runtime,
          references,
          schedule,
          actor,
          geometry,
          learning,
          seed,
          0,
          role,
          output,
          output,
          behavior,
          [0],
          clip_ids,
          variant,
        )
        records.append(group.records)
        let returns = physical_returns(
          group.batch,
          clip_ids,
          number(learning, "gamma"),
        )
        let mut prefix_change = 0.0
        let mut full_change = 0.0
        guard returns.length() == baseline_returns.length() else {
          fail("tail probe baseline return count differs")
        }
        for i in 0..<returns.length() {
          prefix_change += number(returns[i], "prefix_return") -
            number(baseline_returns[i], "prefix_return")
          full_change += number(returns[i], "full_return") -
            number(baseline_returns[i], "full_return")
        }
        outcomes.push({
          "logit_rms_target": amplitude.to_json(),
          "sign": sign.to_json(),
          "coefficient": amount.to_json(),
          "achieved_logit_rms": achieved.to_json(),
          "predicted_return_before": predicted_before.to_json(),
          "predicted_return_after": predicted_after.to_json(),
          "predicted_change": (predicted_after - predicted_before).to_json(),
          "trials": group.trials.to_json(),
          "returns": returns.to_json(),
          "prefix_change_mean": (prefix_change / returns.length().to_double()).to_json(),
          "full_change_mean": (full_change / returns.length().to_double()).to_json(),
        })
      }
    }
    actor.set_parameters(base)
    guard model.network.parameters == frozen_model else {
      fail("prefix probe changed frozen model")
    }
    rows.push(
      merge(reused, {
        "tail_mode": "prefix-only",
        "physics_reused": false,
        "direction_file": direction_file.to_json(),
        "direction_sha256": direction_sha.to_json(),
        "gradient_norm": gradient_norm.to_json(),
        "calibration_response": response.to_json(),
        "outcomes": outcomes.to_json(),
        "critic_used": false,
        "frozen_model_unchanged": true,
      }),
    )
  }
  ignore(
    @artifacts.save_json(output + "/report.json", {
      "format": "moonrobo.moonbit-reference-tail-directions.v1",
      "config": config,
      "source_study": source.to_json(),
      "model_source_study": model_source.to_json(),
      "references": references_path.to_json(),
      "reference_manifest_sha256": field(previous, "reference_manifest_sha256"),
      "baseline_trials": field(previous, "baseline_trials"),
      "baseline_returns": baseline_returns.to_json(),
      "runs": rows.to_json(),
      "physical_records": records.to_json(),
      "reused_physical_records": reused_count.to_json(),
      "new_physical_records": (records.length() - reused_count).to_json(),
      "provider_seconds": ((@async.now() - started).to_double() / 1000).to_json(),
      "physical_execution_allowed": false,
      "release_qualified": false,
      "scope": "paired local physical gradient diagnostics from frozen models; no training, selection or qualification",
    }),
  )
}
