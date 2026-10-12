///|
let usage : String =
  #|telemetry_smooth INPUT.csv CHANNEL[,CHANNEL...] --half-window-ms MS --max-gap-ms MS [--csv [--segment N]]
  #|Offline centered, time-weighted moving mean of the piecewise-linear recorded curve.
  #|Complete windows only; no extrapolation or smoothing across source gaps > max-gap-ms.
  #|Output stays at supported source timestamps, in unchanged units, with .mean labels.
  #|JSON retains selected raw values, window bounds, source spans and unsupported centers.
  #|Disconnected CSV requires --segment. Keep JSON and original input beside derived CSV.
  #|Centered filtering uses future observations, can hide peaks, and is not physical proof.

///|
fn run(args : Array[String]) -> Unit raise {
  if args.length() == 2 && (args[1] == "--help" || args[1] == "-h") {
    println(usage)
    return
  }
  guard args.length() >= 3 else { fail(usage) }
  let mut half_window_ms = 0L
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
    guard ["--half-window-ms", "--max-gap-ms", "--segment"].contains(flag) else {
      fail("unknown option: " + flag)
    }
    guard i + 1 < args.length() else { fail("missing value for " + flag) }
    let value = @string.parse_int64(args[i + 1]) catch {
      _ => fail("invalid integer for " + flag)
    }
    match flag {
      "--half-window-ms" => half_window_ms = value
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
  for required in ["--half-window-ms", "--max-gap-ms"] {
    if !seen.contains(required) {
      fail("missing required option: " + required)
    }
  }
  if segment is Some(_) && !csv {
    fail("--segment requires --csv; JSON always reports the complete report")
  }
  let text = @fsx.read_file_to_string(args[1]) catch {
    _ => fail("cannot read input CSV")
  }
  let channels = args[2].split(",").map(s => s.to_string()).collect()
  let result = match
    @telemetry.smooth_csv(text, channels, half_window_ms~, max_gap_ms~) {
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
      ({ "input_file": args[1].to_json(), "smooth": result.to_json() } : Json).stringify(
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
