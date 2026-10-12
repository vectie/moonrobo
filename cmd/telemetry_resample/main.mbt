///|
let usage : String =
  #|telemetry_resample INPUT.csv CHANNEL[,CHANNEL...] --start-ms MS --end-ms MS --step-ms MS --max-gap-ms MS [--csv [--segment N]]
  #|Offline fixed-grid piecewise-linear channel reconstruction. Grid is anchored at start-ms.
  #|Exact observations are kept; interpolation requires a source interval <= max-gap-ms.
  #|No extrapolation, filtering, unit conversion or hardware action. Max 100000 grid points.
  #|JSON preserves brackets, omitted times and every source gap, including sub-grid gaps.
  #|Disconnected output requires --segment for CSV; segment IDs are zero-based in JSON.
  #|Keep JSON with CSV. Derived points are estimates, not additional measurements.

///|
fn run(args : Array[String]) -> Unit raise {
  if args.length() == 2 && (args[1] == "--help" || args[1] == "-h") {
    println(usage)
    return
  }
  guard args.length() >= 3 else { fail(usage) }
  let mut start_ms = 0L
  let mut end_ms = 0L
  let mut step_ms = 0L
  let mut max_gap_ms = 0L
  let mut segment : Int? = None
  let mut csv = false
  let seen : Array[String] = []
  for i = 3; i < args.length(); {
    let flag = args[i]
    if seen.contains(flag) {
      fail("duplicate option: " + flag)
    }
    seen.push(flag)
    if flag == "--csv" {
      csv = true
      continue i + 1
    }
    guard ["--start-ms", "--end-ms", "--step-ms", "--max-gap-ms", "--segment"].contains(
      flag,
    ) else {
      fail("unknown option: " + flag)
    }
    guard i + 1 < args.length() else { fail("missing value for " + flag) }
    let value = @string.parse_int64(args[i + 1]) catch {
      _ => fail("invalid integer for " + flag)
    }
    match flag {
      "--start-ms" => start_ms = value
      "--end-ms" => end_ms = value
      "--step-ms" => step_ms = value
      "--max-gap-ms" => max_gap_ms = value
      _ => {
        guard value >= 0L && value <= 2147483647L else {
          fail("invalid segment ID")
        }
        segment = Some(value.to_int())
      }
    }
    continue i + 2
  }
  for required in ["--start-ms", "--end-ms", "--step-ms", "--max-gap-ms"] {
    if !seen.contains(required) {
      fail("missing required option: " + required)
    }
  }
  if segment is Some(_) && !csv {
    fail("--segment requires --csv; JSON always reports the complete grid")
  }
  let text = @fsx.read_file_to_string(args[1]) catch {
    _ => fail("cannot read input CSV")
  }
  let channels = args[2].split(",").map(s => s.to_string()).collect()
  let result = match
    @telemetry.resample_csv(
      text,
      channels,
      start_ms~,
      end_ms~,
      step_ms~,
      max_gap_ms~,
    ) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  if csv {
    let output = match result.to_csv(segment?) {
      Ok(value) => value
      Err(message) => fail(message)
    }
    println(output.trim_end())
  } else {
    println(
      ({ "input_file": args[1].to_json(), "resample": result.to_json() } : Json).stringify(
        indent=2,
      ),
    )
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
