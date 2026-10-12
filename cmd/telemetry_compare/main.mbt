///|
let usage : String =
  #|telemetry_compare BASELINE.csv CANDIDATE.csv [--channels NAME,NAME] [--window START_MS END_MS] [--max-gap-ms MS] [--csv]
  #|Compare candidate minus baseline by elapsed time since each file's first sample.
  #|Default: common channels, all times, exact matches only, JSON output.
  #|--max-gap-ms enables linear interpolation across candidate intervals up to MS.
  #|--window bounds are inclusive elapsed milliseconds. --csv exports paired values and gaps.
  #|Use matching channel units and comparable run starts; neither is inferred or converted.

///|
fn report_error(message : String) -> Unit {
  println(({ "error": message } : Json).stringify())
  @sys.exit(2)
}

///|
fn argument_ms(text : String, flag : String) -> Int64 raise {
  @string.parse_int64(text) catch {
    _ => fail("invalid integer for " + flag)
  }
}

///|
fn run(args : Array[String]) -> Unit raise {
  if args.length() == 2 && (args[1] == "--help" || args[1] == "-h") {
    println(usage)
    return
  }
  guard args.length() >= 3 else { fail(usage) }
  let mut channels : Array[String]? = None
  let mut start_ms = 0L
  let mut end_ms = 9223372036854775807L
  let mut max_gap_ms = 0L
  let mut csv = false
  let seen : Array[String] = []
  for i = 3; i < args.length(); {
    let flag = args[i]
    if seen.contains(flag) {
      fail("duplicate option: " + flag)
    }
    seen.push(flag)
    match flag {
      "--csv" => {
        csv = true
        continue i + 1
      }
      "--channels" => {
        guard i + 1 < args.length() else {
          fail("missing value for --channels")
        }
        channels = Some(
          args[i + 1].split(",").map(s => s.trim().to_owned()).collect(),
        )
        continue i + 2
      }
      "--window" => {
        guard i + 2 < args.length() else {
          fail("--window requires START_MS END_MS")
        }
        start_ms = argument_ms(args[i + 1], flag)
        end_ms = argument_ms(args[i + 2], flag)
        continue i + 3
      }
      "--max-gap-ms" => {
        guard i + 1 < args.length() else {
          fail("missing value for --max-gap-ms")
        }
        max_gap_ms = argument_ms(args[i + 1], flag)
        continue i + 2
      }
      _ => fail("unknown option: " + flag)
    }
  }
  let baseline = @fsx.read_file_to_string(args[1]) catch {
    _ => fail("cannot read baseline CSV")
  }
  let candidate = @fsx.read_file_to_string(args[2]) catch {
    _ => fail("cannot read candidate CSV")
  }
  let result = match
    @telemetry.compare_csv(
      baseline,
      candidate,
      channels?,
      start_ms~,
      end_ms~,
      max_gap_ms~,
    ) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  if csv {
    println(result.to_csv().trim_end())
  } else {
    println(
      (
        {
          "baseline_file": args[1].to_json(),
          "candidate_file": args[2].to_json(),
          "comparison": result.to_json(),
        } : Json).stringify(indent=2),
    )
  }
}

///|
fn main {
  run(@env.args()) catch {
    error => report_error(error.to_string())
  }
}
