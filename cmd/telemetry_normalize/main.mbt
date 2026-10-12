///|
let usage : String =
  #|telemetry_normalize INPUT.csv RECIPE.json [--csv]
  #|Explicit local channel mappings: output = input * scale + offset.
  #|Recipe: JSON array of source, target, scale, offset, source_unit, target_unit objects.
  #|Unlisted channels pass through unchanged. Timestamps and column order are preserved.
  #|Default: JSON provenance report. --csv: reusable numeric CSV; retain the report too.
  #|Labels and coefficients are supplied by you; no unit or calibration inference.

///|
fn run(args : Array[String]) -> Unit raise {
  if args.length() == 2 && (args[1] == "--help" || args[1] == "-h") {
    println(usage)
    return
  }
  guard args.length() == 3 || (args.length() == 4 && args[3] == "--csv") else {
    fail(usage)
  }
  let text = @fsx.read_file_to_string(args[1]) catch {
    _ => fail("cannot read input CSV")
  }
  let recipe_text = @fsx.read_file_to_string(args[2]) catch {
    _ => fail("cannot read recipe JSON")
  }
  let mappings = match @telemetry.parse_normalization_recipe(recipe_text) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  let result = match @telemetry.normalize_csv(text, mappings) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  if args.length() == 4 {
    match result.to_csv() {
      Ok(value) => println(value.trim_end())
      Err(message) => fail(message)
    }
  } else {
    println(
      (
        {
          "input_file": args[1].to_json(),
          "recipe_file": args[2].to_json(),
          "normalization": result.to_json(),
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
