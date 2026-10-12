///|
let usage : String =
  #|telemetry_frame INPUT.csv RECIPE.json [--csv]
  #|Convert recorded planar POSITION channels by p_target = R(yaw) * p_source + translation.
  #|Positive yaw_degrees rotates counterclockwise; translation is the source origin in target coordinates.
  #|Recipe: source_x, source_y, target_x, target_y, source_frame, target_frame, units,
  #|yaw_degrees [-180,180], translation_x, translation_y. All ten fields are required.
  #|All original channels/timestamps are retained; target X/Y must be new names.
  #|Default: JSON with recipe and numeric source lineage. --csv: reusable appended columns.
  #|Frames/units are user assertions. No calibration, orientation, vector or covariance conversion.

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
  let recipe = match @telemetry.parse_frame_recipe(recipe_text) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  let result = match @telemetry.transform_frame_csv(text, recipe) {
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
          "transform": result.to_json(),
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
