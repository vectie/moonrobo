///|
let usage : String =
  #|telemetry_correlation INPUT.csv --left NAME --right NAME --max-lag SAMPLES [--window START_MS END_MS] [--csv | --svg]
  #|Overlap-wise Pearson correlation of two channels in 3..2048 uniform recorded observations.
  #|Positive lag pairs left[i] with later right[i+lag]; every lag needs at least 3 pairs.
  #|Default JSON retains original samples and source SHA-256. Constant variance is undefined.
  #|No resampling, clock correction, significance test, delay calibration or causal claim.

///|
fn run(args : Array[String]) -> Unit raise {
  if args.length() == 2 && (args[1] == "--help" || args[1] == "-h") {
    println(usage)
    return
  }
  guard args.length() >= 8 else { fail(usage) }
  let mut left : String? = None
  let mut right : String? = None
  let mut max_lag : Int? = None
  let mut start_ms = 0L
  let mut end_ms = 9223372036854775807L
  let mut output = "json"
  let seen : Array[String] = []
  for i = 2; i < args.length(); {
    let flag = args[i]
    guard !seen.contains(flag) else { fail("duplicate option: " + flag) }
    seen.push(flag)
    match flag {
      "--left" | "--right" | "--max-lag" => {
        guard i + 1 < args.length() else { fail(flag + " requires a value") }
        match flag {
          "--left" => left = Some(args[i + 1])
          "--right" => right = Some(args[i + 1])
          _ => max_lag = Some(@string.parse_int(args[i + 1]))
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
      "--csv" | "--svg" => {
        guard output == "json" else { fail("choose only one output format") }
        output = if flag == "--csv" { "csv" } else { "svg" }
        continue i + 1
      }
      _ => fail("unknown option: " + flag)
    }
  }
  guard left is Some(left) && right is Some(right) && max_lag is Some(max_lag) else {
    fail("--left, --right and --max-lag are required")
  }
  let bytes = @fsx.read_file_to_bytes(args[1])
  guard bytes.length() <= 4194304 else { fail("input exceeds 4 MiB") }
  let report = match
    @telemetry.correlation_csv(
      @utf8.decode(bytes),
      left,
      right,
      max_lag_samples=max_lag,
      start_ms~,
      end_ms~,
    ) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  match output {
    "csv" => println(report.to_csv().trim_end())
    "svg" => println(report.to_svg().trim_end())
    _ =>
      println(
        (
          {
            "format": "moonrobo.telemetry-correlation-file.v1",
            "source_sha256": @crypto.bytes_to_hex_string(@crypto.sha256(bytes)).to_json(),
            "correlation": report.to_json(),
          } : Json).stringify(indent=2),
      )
  }
}

///|
fn main {
  run(@env.args()) catch {
    error => {
      println("telemetry_correlation: \{error}")
      @sys.exit(1)
    }
  }
}
