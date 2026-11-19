///|
fn export_field(value : Json, key : String) -> Json raise {
  guard value is Object(fields) && fields.get(key) is Some(field) else {
    fail("missing export field: " + key)
  }
  field
}

///|
fn export_array(value : Json) -> Array[Json] raise {
  guard value is Array(items) else { fail("export array required") }
  items
}

///|
fn export_string(value : Json) -> String raise {
  guard value is String(text) else { fail("export string required") }
  text
}

///|
fn export_number(value : Json) -> Double raise {
  guard value is Number(number, ..) && finite(number) else {
    fail("finite export number required")
  }
  number
}

///|
pub fn summarize_recorded_trials(trials : Array[Json]) -> Json raise {
  guard !trials.is_empty() else { fail("cannot summarize empty trial set") }
  let mut falls = 0
  let mut survival = 0.0
  let mut rmse = 0.0
  for trial in trials {
    match export_field(trial, "failed") {
      True => falls += 1
      False => ()
      _ => fail("trial failed field must be boolean")
    }
    survival += export_number(export_field(trial, "simulated_seconds")) /
      trials.length().to_double()
    rmse += export_number(export_field(trial, "joint_rmse_rad")) /
      trials.length().to_double()
  }
  {
    "trials": trials.length().to_json(),
    "falls": falls.to_json(),
    "mean_survival_s": survival.to_json(),
    "mean_joint_rmse_rad": rmse.to_json(),
  }
}

///|
/// Validate a recorded JSONL evaluation archive without re-running policy inference. Short views require separately reconstructed replay arrays, keyed by episode identity, to avoid inventing contact geometry.
pub fn read_evaluations(
  raw : Bytes,
  expected_sha256 : String,
  compressed : Bool,
  short : Bool,
  replays : Map[String, Json],
) -> Map[(Int32, String), Json] raise {
  guard @artifacts.sha256(raw) == expected_sha256 else {
    fail("evaluation archive changed")
  }
  let bytes = if compressed { @artifacts.decompress(raw) } else { raw }
  let rows = @utf8.decode(bytes)
  let result : Map[(Int32, String), Json] = {}
  for line in rows.split("\n") {
    if line.trim_space().is_empty() {
      continue
    }
    let row = @json.parse(line)
    let episodes = export_array(
      export_field(export_field(row, "dataset"), "episodes"),
    )
    let recorded = export_array(export_field(row, "trials"))
    guard episodes.length() == recorded.length() else {
      fail("evaluation episodes and trials are misaligned")
    }
    let trials : Array[Json] = []
    for i in 0..<episodes.length() {
      let episode = episodes[i]
      let trial = recorded[i]
      if short &&
        export_string(export_field(trial, "scope")) != "canonical-development" {
        continue
      }
      let ident = export_string(export_field(episode, "id"))
      guard export_string(export_field(trial, "episode_id")) == ident &&
        export_number(export_field(trial, "steps")) ==
        export_array(export_field(episode, "steps")).length().to_double() else {
        fail("recorded trial does not match physics episode")
      }
      let updated = if short {
        guard trial is Object(fields) && replays.get(ident) is Some(replay) else {
          fail("missing reconstructed replay: " + ident)
        }
        let fields = fields.copy()
        fields["replay"] = replay
        Json::object(fields)
      } else {
        trial
      }
      trials.push(updated)
    }
    guard !trials.is_empty() else {
      fail("evaluation row has no selected trials")
    }
    let seed = export_number(export_field(row, "seed"))
    guard seed.to_int().to_double() == seed else {
      fail("evaluation seed must be integer")
    }
    let mode = export_string(export_field(row, "mode"))
    let key = (seed.to_int(), mode)
    guard !result.contains(key) else { fail("duplicate evaluation seed/mode") }
    result[key] = {
      "summary": summarize_recorded_trials(trials),
      "trials": trials.to_json(),
      "replay_source": (if short {
        "geometry/contact reconstruction from recorded next_state; no policy rerun"
      } else {
        "captured during the physical rollout"
      }).to_json(),
    }
  }
  result
}

///|
pub async fn run_export_evaluations(
  source : String,
  expected_sha256 : String,
  output : String,
) -> Json {
  let values = read_evaluations(
    @fs.read_file(source).binary(),
    expected_sha256,
    source.has_suffix(".gz"),
    false,
    {},
  )
  let evaluations : Array[Json] = []
  for (seed, mode), value in values {
    evaluations.push({
      "seed": seed.to_json(),
      "mode": mode.to_json(),
      "evaluation": value,
    })
  }
  let report : Json = {
    "format": "moonrobo.moonbit-balance-recorded-export.v1",
    "evaluations": evaluations.to_json(),
    "source_sha256": expected_sha256.to_json(),
    "physical_execution_allowed": false,
    "release_qualified": false,
  }
  @fs.write_file(
    output,
    @utf8.encode(report.stringify()),
    create_mode=CreateOrTruncate,
  )
  report
}

///|
pub async fn run_export_training_npz(
  data_path : String,
  output : String,
) -> String {
  let raw = @fs.read_file(data_path).binary()
  let bytes = if data_path.has_suffix(".gz") {
    @artifacts.decompress(raw)
  } else {
    raw
  }
  let data : BalanceTrainingData = @json.from_json(
    @json.parse(@utf8.decode(bytes)),
  )
  data.validate()
  let arrays : Map[String, @artifacts.NumericArray] = {}
  for
    (name, rows) in [
      ("observations", data.observations),
      ("goals", data.goals),
      ("targets", data.targets),
      ("features", data.features),
    ] {
    let values : Array[Double] = []
    for row in rows {
      values.append(row)
    }
    arrays[name] = {
      shape: [rows.length(), rows[0].length()],
      dtype: "<f8",
      values,
    }
  }
  @artifacts.save_npz(output, arrays)
}
