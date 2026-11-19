///|
fn field(value : Json, key : String) -> Json raise {
  guard value is Object(fields) && fields.get(key) is Some(result) else {
    fail("missing refit verification field: " + key)
  }
  result
}

///|
async fn checkpoint_path(stem : String) -> String {
  let paths = []
  for suffix in [".moon.json", ".pt", ".json"] {
    if @fs.exists(stem + suffix) {
      paths.push(stem + suffix)
    }
  }
  guard paths.length() == 1 else {
    fail("refit checkpoint missing or ambiguous: " + stem)
  }
  paths[0]
}

///|
pub(all) struct Variant {
  name : String
  representation : String
  output_bound : Double
  control_waist : Bool
} derive(Debug, FromJson)

///|
/// Refit every saved sustained variant from the recorded train-only corpus and demand exact normalized means/scales/coefficients. Legacy Torch weights use the restricted passive reader; Float32/Double differences fail this exact gate.
pub async fn run(folder : String) -> Json {
  let config = @artifacts.load_json(folder + "/config.json")
  let report = @artifacts.load_json(folder + "/report.json")
  let charter = @artifacts.load_json(folder + "/charter.json")
  let original : String = @json.from_json(
    field(charter, "original_balance_study"),
  )
  let collection = @artifacts.load_json(original + "/collection.json")
  let cases : Array[@native_physics.Case] = @json.from_json(
    field(collection, "cases"),
  )
  let allowed = cases.filter(fn(c) { c.split == "train" }).map(fn(c) { c.id })
  let seeds : Array[Int32] = @json.from_json(field(config, "seeds"))
  let training_seeds : Array[Int32] = @json.from_json(
    field(config, "training_reset_seeds"),
  )
  let variants : Array[Variant] = @json.from_json(field(config, "variants"))
  guard !variants.is_empty() && !seeds.is_empty() else {
    fail("empty sustained refit variants/seeds")
  }
  let first = checkpoint_path(
    folder +
    "/policy/actor-" +
    variants[0].name +
    "-seed-" +
    seeds[0].to_string(),
  )
  let policy = @balance_policy.load(first, sustained=true)
  guard policy.head is Sustained(saved_head) else {
    fail("sustained head required")
  }
  let names = Array::makei(policy.geometry.nu, fn(i) {
    "joint-" + i.to_string()
  })
  for
    i, name in [
      "left_ankle_pitch_joint", "left_ankle_roll_joint", "right_ankle_pitch_joint",
      "right_ankle_roll_joint",
    ] {
    names[saved_head.ankle.indices[i]] = name
  }
  names[saved_head.waist_index] = "waist_pitch_joint"
  let observations : Array[Array[Double]] = []
  let goals : Array[Array[Double]] = []
  let targets : Array[Array[Double]] = []
  let features : Array[Array[Double]] = []
  let ids : Array[String] = []
  let seen : Map[String, Bool] = {}
  let source_path = folder + "/teacher-training.jsonl.gz"
  for row in @artifacts.load_jsonl(source_path) {
    guard field(row, "role") is String("teacher-training") else {
      fail("non-training role in fit corpus")
    }
    let episodes : Array[@native_physics.Episode] = @json.from_json(
      field(field(row, "dataset"), "episodes"),
    )
    let trials : Array[Json] = @json.from_json(field(row, "trials"))
    guard episodes.length() == trials.length() else {
      fail("training episode/trial lengths differ")
    }
    for i, episode in episodes {
      let seed : Int32 = @json.from_json(field(trials[i], "seed"))
      guard episode.split == "train" &&
        allowed.contains(episode.case_id) &&
        training_seeds.contains(seed) else {
        fail("fit corpus includes selection/audit/canonical conditions")
      }
      guard field(trials[i], "episode_id") == episode.id.to_json() &&
        !seen.contains(episode.id) else {
        fail("fit corpus identity mismatch or duplicate")
      }
      seen[episode.id] = true
      ids.push(episode.id)
      let obs = episode.steps.map(fn(s) { s.observation })
      observations.append(obs)
      goals.append(episode.steps.map(fn(s) { s.goal }))
      targets.append(episode.steps.map(fn(s) { s.applied_action }))
      features.append(
        @balance.sequence_features(
          policy.geometry,
          obs,
          policy.dt,
          None,
          GravityGyro,
        ),
      )
    }
  }
  let expected_episodes : Int32 = @json.from_json(
    field(report, "training_episodes"),
  )
  let expected_points : Int32 = @json.from_json(
    field(report, "training_points"),
  )
  guard ids.length() == expected_episodes &&
    observations.length() == expected_points else {
    fail("fit corpus episode/point counts differ")
  }
  let margin : Double = @json.from_json(field(config, "uncensored_margin_rad"))
  let checked : Array[Json] = []
  for variant in variants {
    guard variant.representation == "range" ||
      variant.representation == "pose_rate" else {
      fail("unsupported sustained representation")
    }
    let fitted = @balance.SustainedBalanceHead::new(
      names,
      policy.parent.base.lower,
      policy.parent.base.upper,
      pose_rate=variant.representation == "pose_rate",
      control_waist=variant.control_waist,
      output_bound=variant.output_bound,
      fit_bound=saved_head.fit_bound,
    )
    ignore(fitted.fit(observations, goals, targets, features, margin~))
    for seed in seeds {
      let path = checkpoint_path(
        folder + "/policy/actor-" + variant.name + "-seed-" + seed.to_string(),
      )
      let restored = @balance_policy.load(path, sustained=true)
      guard restored.head is Sustained(head) &&
        head.to_json() == fitted.to_json() else {
        fail(
          "saved sustained head cannot be reproduced exactly from train records",
        )
      }
      checked.push({
        "seed": seed.to_json(),
        "variant": variant.name.to_json(),
        "checkpoint_sha256": @artifacts.sha256(@fs.read_file(path).binary()).to_json(),
        "maximum_tensor_error": 0.0,
      })
    }
  }
  let legacy_temporal : @temporal.TemporalPolicy? = Some(
    @temporal.load_temporal(first),
  ) catch {
    _ => None
  }
  let legacy_balance : @balance_policy.BalancePolicy? = Some(
    @balance_policy.load(first),
  ) catch {
    _ => None
  }
  guard legacy_temporal.is_none() && legacy_balance.is_none() else {
    fail("legacy loader accepted sustained v2 action mapping")
  }
  let result : Json = {
    "format": "moonrobo.g1-sustained-balance-refit-verification.v1",
    "training_episodes": ids.length().to_json(),
    "training_points": observations.length().to_json(),
    "training_sha256": @artifacts.sha256(@fs.read_file(source_path).binary()).to_json(),
    "training_episode_ids": ids.to_json(),
    "verified_checkpoints": checked.to_json(),
    "all_tensors_exact": true,
    "legacy_loaders_reject_v2": true,
    "physical_execution_allowed": false,
    "source_language": "moonbit",
    "checkpoint_selection": "unique actual .moon.json/.pt/.json file per declared stem",
  }
  ignore(@artifacts.save_json(folder + "/refit-verification.json", result))
  result
}
