///|
let usage : String =
  #|telemetry_event_compare BASELINE.csv CANDIDATE.csv --event-channel NAME --direction above|below --threshold VALUE --episodes BASELINE_INDEX CANDIDATE_INDEX --window BEFORE_MS AFTER_MS --event-max-gap-ms MS [--event-min-span-ms MS] [--channels NAME,NAME] [--max-gap-ms MS] [--csv]
  #|Register on the first actual sample of each selected qualifying threshold episode.
  #|Episode indices are zero-based after span/gap filtering. Equality breaks episodes.
  #|Window includes signed elapsed times from -BEFORE_MS through AFTER_MS.
  #|--max-gap-ms opts into bounded linear candidate interpolation; default exact-only.
  #|Default output is JSON with anchors and raw timestamps. Keep it beside CSV exports.
  #|Offline observations only: event correspondence, units and clock drift are not inferred.

///|
fn report_error(message : String) -> Unit {
  println(({ "error": message } : Json).stringify())
  @sys.exit(2)
}

///|
fn argument_ms(text : String, flag : String) -> Int64 raise {
  @string.parse_int64(text) catch {
    _ => fail("invalid integer for " + flag)
  }
}

///|
fn argument_index(text : String) -> Int raise {
  @string.parse_int(text) catch {
    _ => fail("invalid episode index")
  }
}

///|
fn run(args : Array[String]) -> Unit raise {
  if args.length() == 2 && (args[1] == "--help" || args[1] == "-h") {
    println(usage)
    return
  }
  guard args.length() >= 3 else { fail(usage) }
  let mut channels : Array[String]? = None
  let mut event_channel = ""
  let mut direction = ""
  let mut threshold = 0.0
  let mut baseline_episode = 0
  let mut candidate_episode = 0
  let mut before_ms = 0L
  let mut after_ms = 0L
  let mut event_max_gap_ms = 0L
  let mut event_min_span_ms = 0L
  let mut max_gap_ms = 0L
  let mut csv = false
  let seen : Array[String] = []
  for i = 3; i < args.length(); {
    let flag = args[i]
    if seen.contains(flag) {
      fail("duplicate option: " + flag)
    }
    seen.push(flag)
    match flag {
      "--csv" => {
        csv = true
        continue i + 1
      }
      "--episodes" | "--window" => {
        guard i + 2 < args.length() else {
          fail("two values required for " + flag)
        }
        if flag == "--episodes" {
          baseline_episode = argument_index(args[i + 1])
          candidate_episode = argument_index(args[i + 2])
        } else {
          before_ms = argument_ms(args[i + 1], flag)
          after_ms = argument_ms(args[i + 2], flag)
        }
        continue i + 3
      }
      "--event-channel"
      | "--direction"
      | "--threshold"
      | "--event-max-gap-ms"
      | "--event-min-span-ms"
      | "--max-gap-ms"
      | "--channels" => {
        guard i + 1 < args.length() else { fail("missing value for " + flag) }
        let value = args[i + 1]
        match flag {
          "--event-channel" => event_channel = value
          "--direction" => direction = value
          "--threshold" =>
            threshold = @string.parse_double(value) catch {
              _ => fail("invalid number for --threshold")
            }
          "--event-max-gap-ms" => event_max_gap_ms = argument_ms(value, flag)
          "--event-min-span-ms" => event_min_span_ms = argument_ms(value, flag)
          "--max-gap-ms" => max_gap_ms = argument_ms(value, flag)
          _ =>
            channels = Some(
              value.split(",").map(s => s.trim().to_owned()).collect(),
            )
        }
        continue i + 2
      }
      _ => fail("unknown option: " + flag)
    }
  }
  for
    required in [
      "--event-channel", "--direction", "--threshold", "--episodes", "--window",
      "--event-max-gap-ms",
    ] {
    if !seen.contains(required) {
      fail("required option: " + required)
    }
  }
  let baseline = @fsx.read_file_to_string(args[1]) catch {
    _ => fail("cannot read baseline CSV")
  }
  let candidate = @fsx.read_file_to_string(args[2]) catch {
    _ => fail("cannot read candidate CSV")
  }
  let result = match
    @telemetry.compare_event_csv(
      baseline,
      candidate,
      event_channel,
      direction,
      threshold,
      baseline_episode~,
      candidate_episode~,
      before_ms~,
      after_ms~,
      event_min_span_ms~,
      event_max_gap_ms~,
      max_gap_ms~,
      channels?,
    ) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  if csv {
    println(result.to_csv().trim_end())
  } else {
    println(
      (
        {
          "baseline_file": args[1].to_json(),
          "candidate_file": args[2].to_json(),
          "event_comparison": result.to_json(),
        } : Json).stringify(indent=2),
    )
  }
}

///|
fn main {
  run(@env.args()) catch {
    error => report_error(error.to_string())
  }
}
