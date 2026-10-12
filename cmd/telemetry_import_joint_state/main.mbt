///|
let usage : String =
  #|telemetry_import_joint_state INPUT.jsonl RECIPE.json [--csv]
  #|Import recorded ROS 2 sensor_msgs/JointState JSON objects, one per line.
  #|Recipe: timestamp_policy plus ordered channels (joint, field, target, unit).
  #|ROS sec/nanosec stamps become strictly increasing nonnegative milliseconds.
  #|Default: JSON report with source line numbers. --csv: reusable numeric CSV.
  #|Retain raw input and report. No unit conversion, live bridge, or hardware action.

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
    _ => fail("cannot read input JSONL")
  }
  let recipe_text = @fsx.read_file_to_string(args[2]) catch {
    _ => fail("cannot read recipe JSON")
  }
  let recipe = match @telemetry.parse_joint_state_recipe(recipe_text) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  let result = match @telemetry.import_joint_state_jsonl(text, recipe) {
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
          "import": result.to_json(),
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
