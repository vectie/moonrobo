///|
fn field(value : Json, name : String) -> Json raise {
  guard value is Object(fields) && fields.get(name) is Some(result) else {
    fail("missing learned export field: " + name)
  }
  result
}

///|
fn text(value : Json, name : String) -> String raise {
  @json.from_json(field(value, name))
}

///|
fn integer(value : Json, name : String) -> Int32 raise {
  @json.from_json(field(value, name))
}

///|
fn number(value : Json, name : String) -> Double raise {
  let result : Double = @json.from_json(field(value, name))
  guard result == result && result - result == 0.0 else {
    fail("nonfinite learned export field: " + name)
  }
  result
}

///|
fn array(value : Json, name : String) -> Array[Json] raise {
  @json.from_json(field(value, name))
}

///|
fn replace(value : Json, fields : Map[String, Json]) -> Json raise {
  guard value is Object(original) else {
    fail("learned export object required")
  }
  let out = original.copy()
  for key, value in fields {
    out[key] = value
  }
  Json::object(out)
}

///|
async fn digest(path : String) -> String {
  @artifacts.sha256(@fs.read_file(path).binary())
}

///|
async fn checkpoint_path(study : String, mode : String, seed : Int32) -> String {
  let prefix = study + "/policy/actor-" + mode + "-seed-" + seed.to_string()
  let matches = []
  for suffix in [".pt", ".moon.json", ".json"] {
    if @fs.exists(prefix + suffix) {
      matches.push(prefix + suffix)
    }
  }
  guard matches.length() == 1 else {
    fail("one unambiguous fitted learned balance head required: " + prefix)
  }
  matches[0]
}

///|
/// A provenance path is passive source data. Native teacher artifacts name
/// their actual MoonBit provider; legacy records retain their original digest.
fn teacher_source(
  teacher : Json,
  charter : Json,
  explicit : String,
) -> String raise {
  guard teacher is Object(teacher_fields) && charter is Object(charter_fields) else {
    fail("teacher and learned charter must be objects")
  }
  let language : String = match teacher_fields.get("source_language") {
    Some(value) => @json.from_json(value)
    None => "python-reference"
  }
  guard ["moonbit", "python", "python-reference"].contains(language) else {
    fail("unknown teacher provider source language")
  }
  let selected : String = if explicit != "" {
    explicit
  } else {
    match teacher_fields.get("provider_source") {
      Some(value) => @json.from_json(value)
      None =>
        match charter_fields.get("teacher_provider_source") {
          Some(value) => @json.from_json(value)
          None => "providers/motion_learning/balance_teacher.py"
        }
    }
  }
  guard !selected.is_empty() &&
    !selected.contains("\u{0}") &&
    (language != "moonbit" || selected.has_suffix(".mbt")) else {
    fail("native teacher source must name the actual MoonBit provider")
  }
  selected
}

///|
fn basename(path : String) -> String {
  path.split("/").last().unwrap().to_owned()
}

///|
pub fn assert_exact_head(
  fitted : @balance.LearnedAnkleHead,
  saved : @balance.LearnedAnkleHead,
) -> Unit raise {
  guard fitted.nu == saved.nu &&
    fitted.indices == saved.indices &&
    fitted.pose_rate == saved.pose_rate &&
    fitted.bound == saved.bound &&
    fitted.lower == saved.lower &&
    fitted.upper == saved.upper &&
    fitted.mean == saved.mean &&
    fitted.scale == saved.scale &&
    fitted.weight == saved.weight else {
    fail(
      "reconstructed training points do not reproduce the saved head exactly; native f64 and legacy f32/OLS differences are not tolerated",
    )
  }
}

///|
async fn read_evaluations(
  runtime : @sim.Runtime,
  folder : String,
  report : Json,
  short : Bool,
  dt : Double,
) -> Map[(Int32, String), Json] {
  let records = @artifacts.load_jsonl(
    folder + "/evaluation-physics.jsonl.gz",
    expected_sha256=text(report, "evaluation_log_sha256"),
  )
  let result : Map[(Int32, String), Json] = Map([])
  for row in records {
    let episodes = array(field(row, "dataset"), "episodes")
    let recorded = array(row, "trials")
    guard episodes.length() == recorded.length() else {
      fail("recorded evaluation trial count differs from physics episodes")
    }
    let trials : Array[Json] = []
    for i, episode in episodes {
      let trial = recorded[i]
      if short && text(trial, "scope") != "canonical-development" {
        continue
      }
      guard text(episode, "id") == text(trial, "episode_id") &&
        array(episode, "steps").length() == integer(trial, "steps") else {
        fail("recorded trial does not match physical episode")
      }
      trials.push(
        if short {
          replace(trial, {
            "replay": @registry.reconstruct_replay(runtime, episode, dt),
          })
        } else {
          trial
        },
      )
    }
    let key = (integer(row, "seed"), text(row, "mode"))
    guard !result.contains(key) else {
      fail("duplicate learned evaluation seed/mode cell")
    }
    result[key] = {
      "summary": @registry.trial_summary(trials),
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
