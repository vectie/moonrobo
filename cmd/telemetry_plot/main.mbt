///|
let usage : String =
  #|telemetry_plot INPUT.csv --channel NAME [--channel NAME ...] [--unit LABEL ...] [--max-gap-ms MS] [--window START_MS END_MS] [--svg]
  #|Plot recorded channels in selection order, with independent Y scales and a shared time axis.
  #|Default JSON; --svg exports a standalone plot. Default gap cutoff: 1000 ms.
  #|Window bounds are inclusive recorded milliseconds; no samples are synthesized.
  #|Unit labels: omit all (unspecified), or supply one --unit per channel in selection order.
  #|Dots are observations. Lines only join observations, not inferred measurements.

///|
fn run(args : Array[String]) -> Unit raise {
  if args.length() == 2 && (args[1] == "--help" || args[1] == "-h") {
    println(usage)
    return
  }
  guard args.length() >= 4 else { fail(usage) }
  let channels : Array[String] = []
  let unit_labels : Array[String] = []
  let mut max_gap_ms = 1000L
  let mut start_ms = 0L
  let mut end_ms = 9223372036854775807L
  let mut svg = false
  let seen : Array[String] = []
  for i = 2; i < args.length(); {
    let flag = args[i]
    if flag != "--channel" && flag != "--unit" && seen.contains(flag) {
      fail("duplicate option: " + flag)
    }
    seen.push(flag)
    match flag {
      "--channel" | "--unit" | "--max-gap-ms" => {
        guard i + 1 < args.length() else { fail(flag + " requires a value") }
        if flag == "--channel" {
          channels.push(args[i + 1])
        } else if flag == "--unit" {
          unit_labels.push(args[i + 1])
        } else {
          max_gap_ms = @string.parse_int64(args[i + 1])
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
      "--svg" => {
        svg = true
        continue i + 1
      }
      _ => fail("unknown option: " + flag)
    }
  }
  let input = @fsx.read_file_to_string(args[1])
  let plot = match
    @telemetry.plot_csv(
      input,
      channels,
      unit_labels~,
      max_gap_ms~,
      start_ms~,
      end_ms~,
    ) {
    Ok(value) => value
    Err(error) => fail(error)
  }
  if svg {
    println(plot.to_svg().trim_end())
  } else {
    println(plot.to_json().stringify(indent=2))
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
