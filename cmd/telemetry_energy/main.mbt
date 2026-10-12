///|
let usage : String =
  #|telemetry_energy INPUT.csv VOLTAGE_CHANNEL CURRENT_CHANNEL --current-polarity discharge-positive|charge-positive --max-gap-ms MS [--csv]
  #|Offline power (W) and observed electrical energy (Wh) from recorded volts and amperes.
  #|Voltage must be nonnegative. Supply units V and A; normalize other units first.
  #|Positive normalized power is draw; negative is recovery. Polarity is never inferred.
  #|Integrates linear sample power, splitting at zero; intervals longer than MS are excluded.
  #|JSON retains raw selected values, intervals and gaps; CSV contains cumulative observed totals.
  #|This is an estimate over supported recording intervals, not battery charge or physical proof.

///|
fn run(args : Array[String]) -> Unit raise {
  if args.length() == 2 && (args[1] == "--help" || args[1] == "-h") {
    println(usage)
    return
  }
  guard args.length() >= 4 else { fail(usage) }
  let mut polarity = ""
  let mut max_gap_ms = 0L
  let mut csv = false
  let seen : Array[String] = []
  for i = 4; i < args.length(); {
    let flag = args[i]
    if seen.contains(flag) {
      fail("duplicate option: " + flag)
    }
    seen.push(flag)
    if flag == "--csv" {
      csv = true
      continue i + 1
    }
    guard flag == "--current-polarity" || flag == "--max-gap-ms" else {
      fail("unknown option: " + flag)
    }
    guard i + 1 < args.length() else { fail("missing value for " + flag) }
    if flag == "--current-polarity" {
      polarity = args[i + 1]
    } else {
      max_gap_ms = @string.parse_int64(args[i + 1]) catch {
        _ => fail("invalid integer for --max-gap-ms")
      }
    }
    continue i + 2
  }
  for required in ["--current-polarity", "--max-gap-ms"] {
    if !seen.contains(required) {
      fail("missing required option: " + required)
    }
  }
  let text = @fsx.read_file_to_string(args[1]) catch {
    _ => fail("cannot read input CSV")
  }
  let energy = match
    @telemetry.energy_csv(
      text,
      args[2],
      args[3],
      current_polarity=polarity,
      max_gap_ms~,
    ) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  if csv {
    let output = match energy.to_csv() {
      Ok(value) => value
      Err(message) => fail(message)
    }
    println(output.trim_end())
  } else {
    println(
      ({ "input_file": args[1].to_json(), "energy": energy.to_json() } : Json).stringify(
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
