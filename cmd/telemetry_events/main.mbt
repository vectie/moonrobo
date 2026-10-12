///|
let usage : String =
  #|telemetry_events INPUT.csv CHANNEL above|below THRESHOLD [--min-span-ms MS] [--max-gap-ms MS] [--csv]
  #|Observed offline sample episodes only. Strict comparison excludes equality.
  #|Default JSON; min span 0, max gap Int64 maximum. Both limits are inclusive.
  #|Positions are zero-based source sample positions; JSON Int64 values are strings.
  #|No crossing interpolation, continuous-duration, incident, readiness or dispatch inference.

///|
fn run(args : Array[String]) -> Unit raise {
  if args.length() == 2 && (args[1] == "--help" || args[1] == "-h") {
    println(usage)
    return
  }
  guard args.length() >= 5 else { fail(usage) }
  let threshold = @string.parse_double(args[4])
  let mut min_span_ms = 0L
  let mut max_gap_ms = 9223372036854775807L
  let mut csv = false
  let seen : Array[String] = []
  for i = 5; i < args.length(); {
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
      "--min-span-ms" | "--max-gap-ms" => {
        guard i + 1 < args.length() else {
          fail(flag + " requires milliseconds")
        }
        let ms = @string.parse_int64(args[i + 1])
        if flag == "--min-span-ms" {
          min_span_ms = ms
        } else {
          max_gap_ms = ms
        }
        continue i + 2
      }
      _ => fail("unknown option: " + flag)
    }
  }
  let input = @fsx.read_file_to_string(args[1])
  let result = match
    @telemetry.threshold_events_csv(
      input,
      args[2],
      args[3],
      threshold,
      min_span_ms~,
      max_gap_ms~,
    ) {
    Ok(value) => value
    Err(error) => fail(error)
  }
  if csv {
    println(result.to_csv().trim_end())
  } else {
    println(result.to_json().stringify(indent=2))
  }
}

///|
fn main {
  run(@env.args()) catch {
    error => {
      println(({ "error": error.to_string() } : Json).stringify())
      @sys.exit(2)
    }
  }
}
