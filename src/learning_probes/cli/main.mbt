///|
fn field(value : Json, key : String) -> Json raise {
  guard value is Object(m) && m.get(key) is Some(v) else {
    fail("missing field: " + key)
  }
  v
}

///|
fn array(value : Json) -> Array[Json] raise {
  guard value is Array(a) else { fail("expected array") }
  a
}

///|
fn number(value : Json) -> Double raise {
  guard value is Number(n) else { fail("expected number") }
  n
}

///|
fn text(value : Json) -> String raise {
  guard value is String(s) else { fail("expected string") }
  s
}

///|
async fn read(path : String) -> Json {
  @json.parse(@fs.read_file(path).text())
}

///|
async fn main {
  let args = @env.args()
  guard args.length() > 1 else {
    fail(
      "usage: summarize-model|verify-teacher [--input report --output path] or [--initial --direction --selected --kind --output]",
    )
  }
  let options : Map[String, String] = {}
  for i = 2; i < args.length(); i = i + 2 {
    if i + 1 >= args.length() {
      fail("missing option value")
    }
    options[args[i]] = args[i + 1]
  }
  guard options.get("--output") is Some(output) else {
    fail("--output is required")
  }
  match args[1] {
    "model" => @study.run_model(options)
    "critic" => @study.run_critic(options)
    "actor-update" => @study.run_actor(options)
    "paired-model" => @study.run_actor(options, paired=true)
    "dynamic-refit" => @study.run_dynamic_refit(options)
    "replay-direction" => @study.run_replay_direction(options)
    "teacher-step" => @study.run_teacher_verification(options)
    "temporal" => @study.run_temporal_probe(options)
    "summarize-model" => {
      guard options.get("--input") is Some(input) else {
        fail("--input is required")
      }
      let report = read(input)
      let config = field(report, "config")
      let raw = array(field(report, "records"))
      // Python versions before translation audits omitted this optional array.
      for row in raw {
        for model in array(field(row, "models")) {
          guard model is Object(m) else { fail("model row must be object") }
          if !m.contains("translation_checks") {
            m["translation_checks"] = [].to_json()
          }
        }
      }
      let records : Array[@probes.Record] = raw.map(row => @json.from_json(row))
      let epsilons = array(field(config, "epsilons_rad"))
      let horizons = array(field(config, "horizons")).map(v => {
        number(v).to_int()
      })
      let mut groups = ["all"]
      if config is Object(m) && m.get("stratify_time") is Some(True) {
        groups = ["all", "before-two-seconds", "after-two-seconds"]
      }
      let summaries : Array[@probes.ModelSummary] = []
      for horizon in horizons {
        for group in groups {
          summaries.append(
            @probes.summarize(records, horizon, group, epsilons.length()),
          )
        }
      }
      guard report is Object(m) else { fail("report must be object") }
      m["summaries"] = summaries.to_json()
      m["summary_provider"] = "MoonBit; original evidence records preserved".to_json()
      @fs.write_file(
        output,
        report.stringify(indent=2),
        create_mode=CreateOrTruncate,
      )
    }
    "verify-teacher" => {
      guard options.get("--initial") is Some(initial_path) &&
        options.get("--selected") is Some(selected_path) &&
        options.get("--direction") is Some(direction_path) &&
        options.get("--kind") is Some(kind) else {
        fail("--initial, --selected, --direction and --kind are required")
      }
      let initial = @artifacts.load_checkpoint(initial_path, kind)
      let selected = @artifacts.load_checkpoint(selected_path, kind)
      let direction = @artifacts.load_checkpoint(
        direction_path, "parameter-direction",
      )
      let digest = @artifacts.sha256(@fs.read_file(initial_path).binary())
      if text(field(direction.metadata, "actor_sha256")) != digest {
        fail("teacher direction actor differs")
      }
      if initial.tensors.length() != selected.tensors.length() {
        fail("selected actor tensor set differs")
      }
      for name, _ in direction.tensors {
        if !initial.tensors.contains(name) {
          fail("direction tensor absent from actor: " + name)
        }
      }
      let mut maximum = 0.0
      let mut bitwise_equal = true
      for name, _ in initial.tensors {
        let origin = initial.tensor(name)
        let result = selected.tensor(name)
        if origin.shape != result.shape {
          fail("selected tensor shape differs: " + name)
        }
        let delta = if direction.tensors.contains(name) {
          let tensor = direction.tensor(name)
          if tensor.shape != origin.shape {
            fail("direction tensor shape differs: " + name)
          }
          tensor.values
        } else {
          Array::make(origin.values.length(), 0.0)
        }
        let (error, equal) = @probes.verify_teacher_step(
          origin.values,
          delta,
          result.values,
        )
        if error > maximum {
          maximum = error
        }
        bitwise_equal = bitwise_equal && equal
      }
      let result : Json = {
        "format": "moonrobo.g1-teacher-first-step-verification.v1",
        "rows": [
          {
            "maximum_parameter_error": maximum,
            "bitwise_equal": bitwise_equal,
            "direction_sha256": @artifacts.sha256(
              @fs.read_file(direction_path).binary(),
            ),
            "actor_sha256": digest,
          },
        ],
        "checkpoint_format": "moonrobo.moonbit-checkpoint.v1",
      }
      @fs.write_file(
        output,
        result.stringify(indent=2),
        create_mode=CreateOrTruncate,
      )
    }
    _ => fail("unknown probe command")
  }
}
