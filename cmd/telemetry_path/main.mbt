///|
let usage : String =
  #|telemetry_path INPUT.csv X_CHANNEL Y_CHANNEL [--units LABEL] [--max-gap-ms MS] [--window START_MS END_MS] [--svg | --csv]
  #|Offline same-unit Cartesian XY positions, in their recorded coordinate frame.
  #|Default: JSON; gaps over 1000 ms disconnect the path. No interpolation or control.
  #|Window bounds are inclusive absolute recorded timestamps; SVG uses equal scales and Y up.
  #|Distance excludes gaps; speed is interval displacement / seconds, not instantaneous speed.

///|
fn run(args : Array[String]) -> Unit raise {
  if args.length() == 2 && (args[1] == "--help" || args[1] == "-h") {
    println(usage)
    return
  }
  guard args.length() >= 4 else { fail(usage) }
  let mut units = "coordinate-units"
  let mut max_gap_ms = 1000L
  let mut start_ms = 0L
  let mut end_ms = 9223372036854775807L
  let mut format = "json"
  let seen : Array[String] = []
  for i = 4; i < args.length(); {
    let flag = args[i]
    if seen.contains(flag) {
      fail("duplicate option: " + flag)
    }
    seen.push(flag)
    match flag {
      "--svg" | "--csv" => {
        if format != "json" {
          fail("choose only one output format")
        }
        format = flag
        continue i + 1
      }
      "--units" => {
        guard i + 1 < args.length() else { fail("--units requires a label") }
        units = args[i + 1]
        continue i + 2
      }
      "--max-gap-ms" => {
        guard i + 1 < args.length() else {
          fail("--max-gap-ms requires milliseconds")
        }
        max_gap_ms = @string.parse_int64(args[i + 1])
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
      _ => fail("unknown option: " + flag)
    }
  }
  let input = @fsx.read_file_to_string(args[1])
  let result = match
    @telemetry.trajectory_csv(
      input,
      args[2],
      args[3],
      units~,
      max_gap_ms~,
      start_ms~,
      end_ms~,
    ) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  match format {
    "--svg" => println(result.to_svg().trim_end())
    "--csv" => println(result.to_csv().trim_end())
    _ => println(result.to_json().stringify(indent=2))
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
