///|
let usage : String =
  #|telemetry_spectrum INPUT.csv --channel NAME --unit LABEL [--window START_MS END_MS] [--demean] [--svg]
  #|One-sided direct-DFT peak-amplitude spectrum of 2..2048 recorded observations.
  #|Require uniform exact positive millisecond spacing throughout the selected window.
  #|Rectangular window; amplitude=abs(DFT)/N, doubled except DC and even-N Nyquist.
  #|Default JSON includes source SHA-256 and original selected observations. --svg draws bins.
  #|No resampling, gap bridging, unit conversion, PSD, hardware or physical diagnosis.

///|
fn run(args : Array[String]) -> Unit raise {
  if args.length() == 2 && (args[1] == "--help" || args[1] == "-h") {
    println(usage)
    return
  }
  guard args.length() >= 6 else { fail(usage) }
  let mut channel : String? = None
  let mut unit : String? = None
  let mut start_ms = 0L
  let mut end_ms = 9223372036854775807L
  let mut demean = false
  let mut svg = false
  let seen : Array[String] = []
  for i = 2; i < args.length(); {
    let flag = args[i]
    guard !seen.contains(flag) else { fail("duplicate option: " + flag) }
    seen.push(flag)
    match flag {
      "--channel" | "--unit" => {
        guard i + 1 < args.length() else { fail(flag + " requires a value") }
        if flag == "--channel" {
          channel = Some(args[i + 1])
        } else {
          unit = Some(args[i + 1])
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
      "--demean" => {
        demean = true
        continue i + 1
      }
      "--svg" => {
        svg = true
        continue i + 1
      }
      _ => fail("unknown option: " + flag)
    }
  }
  guard channel is Some(channel) && unit is Some(unit_label) else {
    fail("--channel and --unit are required")
  }
  let bytes = @fsx.read_file_to_bytes(args[1])
  guard bytes.length() <= 4194304 else { fail("input exceeds 4 MiB") }
  let report = match
    @telemetry.spectrum_csv(
      @utf8.decode(bytes),
      channel,
      unit_label~,
      start_ms~,
      end_ms~,
      demean~,
    ) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  if svg {
    println(report.to_svg().trim_end())
  } else {
    println(
      (
        {
          "format": "moonrobo.telemetry-spectrum-file.v1",
          "source_sha256": @crypto.bytes_to_hex_string(@crypto.sha256(bytes)).to_json(),
          "spectrum": report.to_json(),
        } : Json).stringify(indent=2),
    )
  }
}

///|
fn main {
  run(@env.args()) catch {
    error => {
      eprintln(({ "error": error.to_string() } : Json).stringify())
      @sys.exit(2)
    }
  }
}
