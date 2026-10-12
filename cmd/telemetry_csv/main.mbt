///|
fn report_error(message : String) -> Unit {
  println(({ "error": message } : Json).stringify())
  @sys.exit(2)
}

///|
fn main {
  let args = @env.args()
  if args.length() == 2 && (args[1] == "--help" || args[1] == "-h") {
    println(
      "telemetry_csv INPUT.csv [START_MS END_MS]\nRead offline numeric telemetry; emit JSON to stdout. Time bounds are inclusive.",
    )
    return
  }
  guard args.length() == 2 || args.length() == 4 else {
    report_error("usage: telemetry_csv INPUT.csv [START_MS END_MS]")
    return
  }
  let start_ms = if args.length() == 4 {
    @string.parse_int64(args[2]) catch {
      _ => {
        report_error("invalid START_MS")
        return
      }
    }
  } else {
    0L
  }
  let end_ms = if args.length() == 4 {
    @string.parse_int64(args[3]) catch {
      _ => {
        report_error("invalid END_MS")
        return
      }
    }
  } else {
    9223372036854775807L
  }
  let text = @fsx.read_file_to_string(args[1]) catch {
    _ => {
      report_error("cannot read input CSV")
      return
    }
  }
  match @telemetry.explore_csv(text, start_ms~, end_ms~) {
    Ok(result) => println(result.to_json().stringify(indent=2))
    Err(message) => report_error(message)
  }
}
