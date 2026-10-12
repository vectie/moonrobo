///|
let usage : String =
  #|telemetry_motion INPUT.csv CHANNEL[,CHANNEL] --units UNIT[,UNIT] --order 1|2 --max-gap-ms MS [--csv]
  #|Offline derivatives of explicitly selected recorded position channels.
  #|Order 1: interval-average rate, assigned to the right source timestamp.
  #|Order 2: nonuniform three-point acceleration, assigned to the middle timestamp.
  #|Units label input positions; outputs are those units per second or second squared.
  #|Intervals longer than MS split segments; no estimate crosses a gap.
  #|Default JSON retains source stencils and missing estimates; --csv exports estimates only.
  #|These are noisy finite differences, not measured velocity, safe limits or dispatch commands.

///|
fn run(args : Array[String]) -> Unit raise {
  if args.length() == 2 && (args[1] == "--help" || args[1] == "-h") {
    println(usage)
    return
  }
  guard args.length() >= 3 else { fail(usage) }
  let channels = args[2].split(",").map(s => s.trim().to_owned()).collect()
  let mut units : Array[String] = []
  let mut order = 0
  let mut max_gap_ms = 0L
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
    guard flag == "--units" || flag == "--order" || flag == "--max-gap-ms" else {
      fail("unknown option: " + flag)
    }
    guard i + 1 < args.length() else { fail("missing value for " + flag) }
    match flag {
      "--units" =>
        units = args[i + 1].split(",").map(s => s.trim().to_owned()).collect()
      "--order" =>
        order = @string.parse_int(args[i + 1]) catch {
          _ => fail("invalid integer for --order")
        }
      _ =>
        max_gap_ms = @string.parse_int64(args[i + 1]) catch {
          _ => fail("invalid integer for --max-gap-ms")
        }
    }
    continue i + 2
  }
  for required in ["--units", "--order", "--max-gap-ms"] {
    if !seen.contains(required) {
      fail("missing required option: " + required)
    }
  }
  let text = @fsx.read_file_to_string(args[1]) catch {
    _ => fail("cannot read input CSV")
  }
  let motion = match
    @telemetry.motion_csv(
      text,
      channels,
      unit_labels=units,
      order~,
      max_gap_ms~,
    ) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  if csv {
    let output = match motion.to_csv() {
      Ok(value) => value
      Err(message) => fail(message)
    }
    println(output.trim_end())
  } else {
    println(
      ({ "input_file": args[1].to_json(), "motion": motion.to_json() } : Json).stringify(
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
