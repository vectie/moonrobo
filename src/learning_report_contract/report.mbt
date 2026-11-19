///|
/// Snapshot actual implementation sources. The key names are the public digest fields;
/// retained Python reference sources must never stand in for native implementation.
pub async fn capture(
  output : String,
  definitions : Array[(String, String)],
) -> Json {
  let directory = output + "/provider-sources"
  if !@fs.exists(directory) {
    @fs.mkdir(directory, recursive=true)
  }
  let sources : Map[String, Json] = {}
  for (key, source) in definitions {
    guard source.has_suffix(".mbt") || source.has_suffix(".py") else {
      fail("report source must have its actual source extension")
    }
    let native = source.has_suffix(".mbt")
    guard native || key == "teacher_provider_sha256" else {
      fail("Python is permitted only as passive teacher-parameter provenance")
    }
    guard !sources.contains(key) else {
      fail("duplicate native source digest key")
    }
    let raw = @fs.read_file(source).binary()
    let snapshot = "provider-sources/" +
      key +
      (if native { ".mbt" } else { ".py" })
    @fs.write_file(output + "/" + snapshot, raw, create_mode=CreateOrTruncate)
    sources[key] = {
      "source": source.to_json(),
      "snapshot": snapshot.to_json(),
      "sha256": @artifacts.sha256(raw).to_json(),
      "role": (if native {
        "native-implementation"
      } else {
        "passive-parameter-source"
      }).to_json(),
    }
  }
  sources.to_json()
}

///|
pub async fn attach(report : Json, sources : Json) -> Json {
  guard report is Object(fields) && sources is Object(bindings) else {
    fail("native report source objects required")
  }
  let fields = fields.copy()
  for key, entry in bindings {
    guard entry is Object(values) &&
      values.get("source") is Some(String(source)) &&
      values.get("sha256") is Some(String(expected)) else {
      fail("invalid native source binding")
    }
    guard @artifacts.sha256(@fs.read_file(source).binary()) == expected else {
      fail("native implementation changed during study: " + source)
    }
    fields[key] = expected.to_json()
  }
  fields["native_source_files"] = sources
  fields["source_language"] = "moonbit"
  Json::object(fields)
}

///|
/// Original flat report schema plus its native nested summary, both from the same
/// recorded trials. Per-case means use their own actual denominator.
pub fn pooled(trials : Array[Json], labels : Json) -> Json raise {
  guard labels is Object(labels) &&
    @balance.summarize_recorded_trials(trials) is Object(summary) else {
    fail("pooled report objects required")
  }
  let result = labels.copy()
  for key, value in summary {
    result[key] = value
  }
  result["summary"] = Json::object(summary)
  let grouped : Map[String, Array[Json]] = {}
  for trial in trials {
    guard trial is Object(fields) && fields.get("case_id") is Some(String(id)) else {
      fail("trial case identity missing")
    }
    if !grouped.contains(id) {
      grouped[id] = []
    }
    grouped[id].push(trial)
  }
  let cases : Array[Json] = []
  let names = grouped.keys().to_array()
  names.sort()
  for id in names {
    guard @balance.summarize_recorded_trials(grouped[id]) is Object(fields) else {
      fail("case summary object required")
    }
    fields["case_id"] = id.to_json()
    cases.push(Json::object(fields))
  }
  result["cases"] = cases.to_json()
  Json::object(result)
}
