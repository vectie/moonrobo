///|
let usage : String =
  #|telemetry_planar BASELINE.csv CANDIDATE.csv RECIPE.json [--window START_MS END_MS] [--max-gap-ms MS] [--csv | --svg]
  #|Offline paired XY positions, Euclidean separation, source lineage and overlay.
  #|Recipe explicitly declares both X/Y channels, equal units/frame and alignment.
  #|Alignment: first-sample or absolute-timestamp. Window bounds are inclusive in that timebase.
  #|Default: all times, exact matches only, JSON. Positive --max-gap-ms enables bounded linear interpolation and route connections.
  #|No frame/unit inference, motion control, readiness or physical outcome claims.

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
  guard args.length() >= 4 else { fail(usage) }
  let mut start_ms = 0L
  let mut end_ms = 9223372036854775807L
  let mut max_gap_ms = 0L
  let mut csv = false
  let mut svg = false
  let seen : Array[String] = []
  for i = 4; i < args.length(); {
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
      "--svg" => {
        svg = true
        continue i + 1
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
  if csv && svg {
    fail("choose only one of --csv or --svg")
  }
  let recipe_text = @fsx.read_file_to_string(args[3]) catch {
    _ => fail("cannot read planar recipe")
  }
  let recipe = match @telemetry.parse_planar_recipe(recipe_text) {
    Ok(v) => v
    Err(e) => fail(e)
  }
  let baseline = @fsx.read_file_to_string(args[1]) catch {
    _ => fail("cannot read baseline CSV")
  }
  let candidate = @fsx.read_file_to_string(args[2]) catch {
    _ => fail("cannot read candidate CSV")
  }
  let result = match
    @telemetry.compare_planar_csv(
      baseline,
      candidate,
      recipe,
      start_ms~,
      end_ms~,
      max_gap_ms~,
    ) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  if csv {
    println(result.to_csv().trim_end())
  } else if svg {
    let output = match result.to_svg() {
      Ok(v) => v
      Err(e) => fail(e)
    }
    println(output.trim_end())
  } else {
    println(
      (
        {
          "baseline_file": args[1].to_json(),
          "candidate_file": args[2].to_json(),
          "comparison": result.to_json(),
          "recipe_file": args[3].to_json(),
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
