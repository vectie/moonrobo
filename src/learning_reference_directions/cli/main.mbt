///|
fn option(options : Map[String, String], key : String) -> String raise {
  guard options.get(key) is Some(value) else { fail("required " + key) }
  value
}

///|
async fn main {
  let args = @env.args()
  if args.length() < 2 {
    fail(
      "usage: action|feedback|export-action|export-feedback --scene XML --library MUJOCO [--source STUDY --output OUTPUT] or [--study STUDY]",
    )
  }
  let options : Map[String, String] = {}
  for i = 2; i < args.length(); i = i + 2 {
    if i + 1 >= args.length() {
      fail("missing option value")
    }
    options[args[i]] = args[i + 1]
  }
  let scene = option(options, "--scene")
  let library = option(options, "--library")
  match args[1] {
    "action" =>
      @directions.run_action_response(
        option(options, "--source"),
        option(options, "--output"),
        scene,
        library,
      )
    "feedback" =>
      @directions.run_feedback_response(
        option(options, "--source"),
        option(options, "--output"),
        scene,
        library,
      )
    "export-action" =>
      @directions.export_action_response(
        option(options, "--study"),
        scene,
        library,
        row => println(row.stringify()),
      )
    "export-feedback" =>
      @directions.export_feedback_response(
        option(options, "--study"),
        scene,
        library,
        row => println(row.stringify()),
      )
    _ => fail("unknown reference direction command")
  }
}
