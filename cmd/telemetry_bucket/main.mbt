///|
let usage : String =
  #|telemetry_bucket INPUT.csv --channel NAME [--channel NAME ...] --width-ms MS --align zero|window --window START_MS END_MS [--csv]
  #|Summarize recorded samples with explicit fixed-width time buckets.
  #|Window and bucket bounds are inclusive integer milliseconds. Boundary samples enter the next bucket.
  #|Alignment origin: zero=0 ms; window=START_MS. Mean weights each selected sample equally.
  #|Default JSON; --csv emits a long-form report with source membership and compressed empty spans.
  #|No interpolation, smoothing, time weighting, unit conversion or physical inference.

///|
fn run(args : Array[String]) -> Unit raise {
  if args.length() == 2 && (args[1] == "--help" || args[1] == "-h") {
    println(usage)
    return
  }
  guard args.length() >= 2 else { fail(usage) }
  let channels : Array[String] = []
  let mut width_ms = 0L
  let mut alignment = ""
  let mut start_ms = 0L
  let mut end_ms = 0L
  let mut csv = false
  let seen : Array[String] = []
  for i = 2; i < args.length(); {
    let flag = args[i]
    if flag != "--channel" && seen.contains(flag) {
      fail("duplicate option: " + flag)
    }
    seen.push(flag)
    match flag {
      "--channel" | "--width-ms" | "--align" => {
        guard i + 1 < args.length() else { fail(flag + " requires a value") }
        if flag == "--channel" {
          channels.push(args[i + 1])
        } else if flag == "--align" {
          alignment = args[i + 1]
        } else {
          width_ms = @string.parse_int64(args[i + 1])
        }
        continue i + 2
      }
      "--window" => {
        guard i + 2 < args.length() else {
          fail("--window requires START_MS END_MS")
        }
        start_ms = @string.parse_int64(args[i + 1])
        end_ms = @string.parse_int64(args[i + 2])
        continue i + 3
      }
      "--csv" => {
        csv = true
        continue i + 1
      }
      _ => fail("unknown option: " + flag)
    }
  }
  for required in ["--channel", "--width-ms", "--align", "--window"] {
    if !seen.contains(required) {
      fail("missing required option: " + required)
    }
  }
  let text = @fsx.read_file_to_string(args[1])
  let report = match
    @telemetry.bucket_csv(
      text,
      channels,
      width_ms~,
      alignment~,
      start_ms~,
      end_ms~,
    ) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  if csv {
    println(report.to_csv().trim_end())
  } else {
    println(report.to_json().stringify(indent=2))
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
