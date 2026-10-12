///|
let usage : String =
  #|telemetry_unwrap INPUT.csv RECIPE.json --max-gap-ms MS [--csv]
  #|Unwrap explicitly selected periodic channels in an offline recording.
  #|Recipe: [{"source":"joint.deg","target":"joint.continuous.deg","period":360,"unit":"deg"}]
  #|Keep every row and untouched channel; split at gaps longer than MS.
  #|Each segment starts from its first raw value; hidden turns are not recovered.
  #|Default JSON retains corrections and half-period ambiguity; --csv exports numeric values.
  #|Assumes true displacement between adjacent observations is less than half the period.
  #|No device connection, calibration, interpolation or physical success claim.

///|
fn run(args : Array[String]) -> Unit raise {
  if args.length() == 2 && (args[1] == "--help" || args[1] == "-h") {
    println(usage)
    return
  }
  guard args.length() >= 3 else { fail(usage) }
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
    guard flag == "--max-gap-ms" else { fail("unknown option: " + flag) }
    guard i + 1 < args.length() else { fail("missing value for " + flag) }
    max_gap_ms = @string.parse_int64(args[i + 1]) catch {
      _ => fail("invalid integer for --max-gap-ms")
    }
    continue i + 2
  }
  if !seen.contains("--max-gap-ms") {
    fail("missing required option: --max-gap-ms")
  }
  let text = @fsx.read_file_to_string(args[1]) catch {
    _ => fail("cannot read input CSV")
  }
  let recipe_text = @fsx.read_file_to_string(args[2]) catch {
    _ => fail("cannot read recipe JSON")
  }
  let recipe = match @telemetry.parse_unwrap_recipe(recipe_text) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  let result = match @telemetry.unwrap_csv(text, recipe, max_gap_ms~) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  if csv {
    let output = match result.to_csv() {
      Ok(value) => value
      Err(message) => fail(message)
    }
    println(output.trim_end())
  } else {
    println(
      (
        {
          "input_file": args[1].to_json(),
          "recipe_file": args[2].to_json(),
          "unwrap": result.to_json(),
        } : Json).stringify(indent=2),
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
