///|
pub async fn sibling_checkpoint(
  actor_path : String,
  prefix : String,
  cycle : Int32,
) -> String {
  let parent = actor_path[:actor_path.length() - path_name(actor_path).length()].to_owned()
  if @fs.exists(parent + prefix + "-cycle-\{cycle}.json") {
    parent + prefix + "-cycle-\{cycle}.json"
  } else {
    parent + prefix + "-cycle-\{cycle}.pt"
  }
}

///|
pub fn model_equal(a : @training.Dynamics, b : @training.Dynamics) -> Bool {
  a.network.parameters == b.network.parameters &&
  a.network.dimensions == b.network.dimensions &&
  a.state_stats.mean == b.state_stats.mean &&
  a.state_stats.scale == b.state_stats.scale &&
  a.action_stats.mean == b.action_stats.mean &&
  a.action_stats.scale == b.action_stats.scale &&
  a.context_stats.mean == b.context_stats.mean &&
  a.context_stats.scale == b.context_stats.scale
}

///|
fn torch_tensor_payload(tensor : @artifacts.NumericArray) -> Bytes raise {
  let bytes : Array[Byte] = []
  for value in tensor.values {
    let (bits, count) = match tensor.dtype {
      "<f4" => (value.to_float().reinterpret_as_int().to_int64(), 4)
      "<f8" => (value.reinterpret_as_int64(), 8)
      "<i8" => (value.to_int64(), 8)
      "<i4" => (value.to_int().to_int64(), 4)
      "|b1" | "|u1" => (value.to_int64(), 1)
      _ => fail("unsupported Torch state digest dtype " + tensor.dtype)
    }
    for i in 0..<count {
      bytes.push(((bits >> (i * 8)) & 255L).to_int().to_byte())
    }
  }
  Bytes::from_array(bytes)
}

///|
pub async fn checkpoint_state_digest(path : String, kind : String) -> String {
  let raw = @fs.read_file(path).binary()
  if raw.length() >= 2 && raw[:2] == b"PK" {
    let data = @artifacts.decode_torch_checkpoint(raw)
    let state = data.field(if kind == "model" { "model" } else { "state_dict" })
    guard state is @artifacts.TorchDict(fields) else {
      fail("Torch state dictionary required")
    }
    let bytes : Array[Byte] = []
    for name, tensor in fields {
      bytes.append(@utf8.encode(name).to_array())
      bytes.append(torch_tensor_payload(tensor.tensor()).to_array())
    }
    return @artifacts.sha256(Bytes::from_array(bytes))
  }
  match kind {
    "actor" => {
      let (actor, _) = load_reference_actor(path)
      state_digest(actor)
    }
    "value" => {
      let value = load_reference_value(path)
      @artifacts.sha256(@utf8.encode(value.to_json().stringify()))
    }
    "model" => {
      let (model, _) = load_reference_dynamics(path)
      @artifacts.sha256(
        @utf8.encode(model.checkpoint(Json::null()).to_json().stringify()),
      )
    }
    _ => fail("unknown checkpoint digest kind")
  }
}

///|
async fn verify_learning_protocols(
  study : String,
  report : Json,
  native_rng : Bool,
  legacy_indices : ((Int64, Array[(Int32, Int32)]) -> Array[Array[Int32]] raise)?,
) -> Unit {
  let config = json_field(report, "config")
  let format = json_text(json_field(config, "format"))
  let seeds = json_array(json_field(config, "seeds"))
  let methods = json_array(json_field(config, "methods"))
  let report_sha = source_digest(study + "/report.json")
  let tail_formats = [
    "moonrobo.g1-reference-tail-training-charter.v1", "moonrobo.g1-reference-state-origin-charter.v1",
    "moonrobo.g1-reference-extended-training-charter.v1", "moonrobo.g1-reference-replay-anchor-charter.v1",
  ]
  if tail_formats.contains(format) {
    let fits : Array[Json] = []
    for seed_json in seeds {
      let seed = json_integer(seed_json)
      let models : Array[@training.Dynamics] = []
      let values : Array[ReferenceValue] = []
      let paths : Array[(String, String)] = []
      for method_name in methods {
        let run = select_run(report, json_text(method_name), seed)
        let checkpoint = json_field(
          json_array(json_field(run, "cycles"))[0],
          "checkpoint",
        )
        let path = path_child(
          study,
          json_text(json_field(checkpoint, "checkpoint")),
        )
        let model_path = sibling_checkpoint(path, "dynamics", 1)
        let value_path = sibling_checkpoint(path, "value", 1)
        models.push(load_reference_dynamics(model_path).0)
        values.push(load_reference_value(value_path))
        paths.push((model_path, value_path))
      }
      guard models.length() >= 2 else {
        fail("paired first-fit verification requires two methods")
      }
      for i in 1..<models.length() {
        guard model_equal(models[0], models[i]) &&
          values[0].to_json() == values[i].to_json() else {
          fail("common first model/value tensors differ between arms")
        }
      }
      fits.push({
        "seed": seed,
        "first_model_state_sha256": checkpoint_state_digest(paths[0].0, "model"),
        "first_value_state_sha256": checkpoint_state_digest(paths[0].1, "value"),
      })
    }
    ignore(
      @artifacts.save_json(study + "/common-fit-verification.json", {
        "format": "moonrobo.g1-reference-common-fit.v1",
        "paired_first_fits_identical": true,
        "seeds": fits,
        "source_report_sha256": report_sha,
      }),
    )
  }
  if [
      "moonrobo.g1-reference-extended-training-charter.v1", "moonrobo.g1-reference-replay-anchor-charter.v1",
    ].contains(format) {
    let checks : Array[Json] = []
    let baseline_method = json_text(
      json_field(config, "reused_baseline_method"),
    )
    let candidates = methods.filter(value => json_text(value) != baseline_method)
    guard candidates.length() == 1 else {
      fail("one candidate reconstruction arm required")
    }
    for seed_json in seeds {
      let seed = json_integer(seed_json)
      let baseline = select_run(report, baseline_method, seed)
      let extended = select_run(report, json_text(candidates[0]), seed)
      let count = json_integer(
        config_default(
          config,
          "reconstruction_cycles",
          json_field(config, "baseline_cycles"),
        ),
      )
      for i in 0..<count {
        let old = json_array(json_field(baseline, "cycles"))[i]
        let new = json_array(json_field(extended, "cycles"))[i]
        let claimed = json_array(
            json_field(extended, "baseline_reconstruction"),
          )[i]
        guard json_integer(json_field(claimed, "cycle")) == i + 1 &&
          json_boolean(json_field(claimed, "all_tensors_identical")) else {
          fail("missing reconstruction check")
        }
        let new_checkpoint = json_field(new, "checkpoint")
        let path = path_child(
          study,
          json_text(json_field(new_checkpoint, "checkpoint")),
        )
        let (actor, _) = load_reference_actor(
          path,
          expected_sha256=json_text(json_field(new_checkpoint, "sha256")),
        )
        let (model, _) = load_reference_dynamics(
          sibling_checkpoint(path, "dynamics", i + 1),
        )
        let value = load_reference_value(
          sibling_checkpoint(path, "value", i + 1),
        )
        ignore(verify_reconstructed_cycle(actor, model, value, old, study))
        let row : Map[String, Json] = {
          "seed": seed.to_json(),
          "cycle": (i + 1).to_json(),
        }
        for
          (kind, file) in [
            ("actor", path),
            ("model", sibling_checkpoint(path, "dynamics", i + 1)),
            ("value", sibling_checkpoint(path, "value", i + 1)),
          ] {
          let hash = checkpoint_state_digest(file, kind)
          guard hash == json_text(json_field(claimed, kind + "_state_sha256")) else {
            fail("reconstruction digest differs")
          }
          row[kind + "_state_sha256"] = hash.to_json()
        }
        checks.push(row.to_json())
      }
    }
    ignore(
      @artifacts.save_json(study + "/reconstruction-verification.json", {
        "format": "moonrobo.g1-reference-reconstruction.v1",
        "all_actor_model_value_tensors_identical": true,
        "cycles": checks,
        "source_report_sha256": report_sha,
      }),
    )
  }
  let by_id : Map[String, Json] = Map([])
  for record in json_array(json_field(report, "physical_records")) {
    by_id[json_text(json_field(record, "episode_id"))] = record
  }
  if format == "moonrobo.g1-reference-replay-anchor-charter.v1" {
    let checks : Array[Json] = []
    for run in json_array(json_field(report, "runs")) {
      if json_text(json_field(run, "method")) != "replay-prefix-anchor" {
        continue
      }
      let seed = json_integer(json_field(run, "seed"))
      let requests : Array[(Int32, Int32)] = []
      let expected : Array[(Int32, Int32)] = []
      let mut total = 0
      let mut initial = 0
      for cycle in json_array(json_field(run, "cycles")) {
        let fresh = json_array(json_field(cycle, "training_episode_ids")).fold(
          init=0,
          (sum, id) => {
            sum +
            (json_integer(json_field(by_id[json_text(id)], "steps")) -
            json_integer(json_field(config, "model_window")) +
            1).max(0)
          },
        )
        total += fresh
        if initial == 0 {
          initial = fresh
        }
        let anchor = if json_integer(json_field(cycle, "cycle")) >
          json_integer(json_field(config, "model_initial_anchor_after_cycle")) {
          initial
        } else {
          0
        }
        let windows = total.min(
          json_integer(json_field(config, "model_replay_windows")),
        )
        let fit = json_field(cycle, "model")
        guard json_integer(json_field(fit, "windows")) == windows &&
          json_integer(json_field(fit, "anchor_windows")) == anchor &&
          json_integer(json_field(fit, "recent_windows")) == windows - anchor &&
          json_text(json_field(fit, "replay_mode")) ==
          (if anchor > 0 { "initial-anchor" } else { "recent-fifo" }) else {
          fail("retained model pool counts differ from frozen replay recipe")
        }
        expected.push((windows, anchor))
        for _ in 0..<json_integer(json_field(config, "model_updates_per_cycle")) {
          requests.push(
            (windows, json_integer(json_field(config, "model_batch_size"))),
          )
        }
      }
      let sampled = if native_rng {
        let rng = @numeric.Rng::new((70000 + seed).reinterpret_as_uint())
        requests.map(request => {
          Array::makei(request.1, _ => rng.index(request.0))
        })
      } else {
        guard legacy_indices is Some(generate) else {
          fail(
            "Torch seeded replay draw verification requires MOONROBO_TORCH_RNG_ADAPTER",
          )
        }
        generate((70000 + seed).to_int64(), requests)
      }
      let updates = json_integer(json_field(config, "model_updates_per_cycle"))
      for i, cycle in json_array(json_field(run, "cycles")) {
        let ids = sampled[i * updates:(i + 1) * updates].to_owned()
        let hash = sample_indices_digest(ids)
        let anchor_samples = ids.fold(init=0, (sum, row) => {
          sum + row.filter(index => index < expected[i].1).length()
        })
        let fit = json_field(cycle, "model")
        guard json_text(json_field(fit, "sample_indices_sha256")) == hash &&
          json_integer(json_field(fit, "anchor_samples")) == anchor_samples else {
          fail("model replay draws differ from original seeded uniform stream")
        }
        checks.push({
          "seed": seed,
          "cycle": json_field(cycle, "cycle"),
          "windows": expected[i].0,
          "anchor_windows": expected[i].1,
          "recent_windows": expected[i].0 - expected[i].1,
          "anchor_samples": anchor_samples,
          "total_samples": updates *
          json_integer(json_field(config, "model_batch_size")),
          "sample_indices_sha256": hash,
        })
      }
    }
    ignore(
      @artifacts.save_json(study + "/model-replay-verification.json", {
        "format": "moonrobo.g1-reference-model-replay-verification.v1",
        "pool_counts_verified": true,
        "seeded_model_draws_verified": true,
        "cycles": checks,
        "source_report_sha256": report_sha,
      }),
    )
  }
  if [
      "moonrobo.g1-reference-state-origin-charter.v1", "moonrobo.g1-reference-extended-training-charter.v1",
      "moonrobo.g1-reference-replay-anchor-charter.v1",
    ].contains(format) {
    let checks : Array[Json] = []
    for run in json_array(json_field(report, "runs")) {
      let method_name = json_text(json_field(run, "method"))
      if !["replay-prefix", "replay-prefix-extended", "replay-prefix-anchor"].contains(
          method_name,
        ) {
        continue
      }
      let seed = json_integer(json_field(run, "seed"))
      let requests : Array[(Int32, Int32)] = []
      let ages_per_cycle : Array[Array[Int32]] = []
      let counts : Array[Int32] = []
      for cycle in json_array(json_field(run, "cycles")) {
        let ages : Array[Int32] = []
        for id in json_array(json_field(cycle, "training_episode_ids")) {
          let n = json_integer(json_field(by_id[json_text(id)], "steps"))
          for age in 0..<n {
            ages.push(age)
          }
        }
        ages_per_cycle.push(ages)
        requests.push(
          (
            ages.length(),
            json_integer(json_field(config, "actor_calibration_batch_size")),
          ),
        )
        let actor = json_field(cycle, "actor")
        guard json_text(json_field(actor, "origin_sampling")) ==
          "trajectory-states" else {
          fail("wrong actor origin mode")
        }
        let steps = json_integer(json_field(actor, "actor_steps"))
        counts.push(steps)
        for _ in 0..<steps {
          requests.push(
            (
              ages.length(),
              json_integer(json_field(config, "actor_batch_size")),
            ),
          )
        }
      }
      let sampled = if native_rng {
        let rng = @numeric.Rng::new((23000 + seed).reinterpret_as_uint())
        requests.map(request => {
          Array::makei(request.1, _ => rng.index(request.0))
        })
      } else {
        guard legacy_indices is Some(generate) else {
          fail(
            "Torch seeded actor origin verification requires MOONROBO_TORCH_RNG_ADAPTER",
          )
        }
        generate((23000 + seed).to_int64(), requests)
      }
      let mut offset = 0
      for i, cycle in json_array(json_field(run, "cycles")) {
        offset += 1
        let samples = json_array(
          json_field(json_field(cycle, "actor"), "actor_origin_samples"),
        )
        guard samples.length() == counts[i] else {
          fail("missing actor origin draws")
        }
        let all_ages : Array[Int32] = []
        for sample in samples {
          let ids : Array[Int32] = @json.from_json(
            json_field(sample, "replay_indices"),
          )
          guard ids == sampled[offset] else {
            fail("actor origins differ from uniform seeded draws")
          }
          offset += 1
          let ages = ids.map(index => ages_per_cycle[i][index])
          all_ages.append(ages)
          let total = ages.fold(init=0, (a, b) => a + b)
          let mean = if native_rng {
            total.to_double() / ages.length().to_double()
          } else {
            (total.to_float() / ages.length().to_float()).to_double()
          }
          guard json_integer(json_field(sample, "minimum_age_steps")) ==
            ages.fold(init=ages[0], (a, b) => a.min(b)) &&
            json_integer(json_field(sample, "maximum_age_steps")) ==
            ages.fold(init=ages[0], (a, b) => a.max(b)) &&
            json_number(json_field(sample, "mean_age_steps")) == mean &&
            json_integer(json_field(sample, "nonreset_samples")) ==
            ages.filter(age => age > 0).length() else {
            fail("actor origin age summary differs from physical episodes")
          }
        }
        let sum = all_ages.fold(init=0, (a, b) => a + b)
        let mean = if native_rng {
          sum.to_double() / all_ages.length().to_double()
        } else {
          (sum.to_float() / all_ages.length().to_float()).to_double()
        }
        checks.push({
          "method": method_name,
          "seed": seed,
          "cycle": json_field(cycle, "cycle"),
          "samples": all_ages.length(),
          "nonreset_samples": all_ages.filter(age => age > 0).length(),
          "mean_age_s": mean * 0.02,
          "maximum_age_s": all_ages
          .fold(init=all_ages[0], (a, b) => a.max(b))
          .to_double() *
          0.02,
        })
      }
    }
    ignore(
      @artifacts.save_json(study + "/actor-origin-verification.json", {
        "format": "moonrobo.g1-reference-actor-origin-verification.v1",
        "seeded_uniform_draws_verified": true,
        "cycles": checks,
        "source_report_sha256": report_sha,
      }),
    )
  }
}
