///|
fn required(options : Map[String, String], name : String) -> String raise {
  guard options.get(name) is Some(value) else { fail("missing " + name) }
  value
}

///|
async fn main {
  let args = @env.args()
  guard args.length() >= 2 && args[1] == "reference-study" else {
    fail(
      "usage: learning-replay reference-study --library LIBMUJOCO --scene SCENE.xml --study REPORT.json --references REFERENCE_DIRECTORY --output NEW_DIRECTORY [--source-directory RECORD_ROOT] [--seed N] [--start-step N] [--clip-ids '[\"motion-id\"]'] [--limit 8]",
    )
  }
  let known = [
    "--library", "--scene", "--study", "--references", "--output", "--source-directory",
    "--seed", "--start-step", "--clip-ids", "--limit",
  ]
  let options : Map[String, String] = Map([])
  for i = 2; i < args.length(); i = i + 2 {
    guard i + 1 < args.length() &&
      known.contains(args[i]) &&
      !options.contains(args[i]) else {
      fail("invalid, duplicate or unpaired replay option: " + args[i])
    }
    options[args[i]] = args[i + 1]
  }
  let clip_ids : Array[String] = @json.from_json(
    @json.parse(options.get("--clip-ids").unwrap_or("[]")),
  )
  let seed = match options.get("--seed") {
    Some(value) => Some(@string.parse_int(value))
    None => None
  }
  let start_step = match options.get("--start-step") {
    Some(value) => Some(@string.parse_int(value))
    None => None
  }
  let result = @producer.export_reference_study(
    library=required(options, "--library"),
    scene=required(options, "--scene"),
    study_path=required(options, "--study"),
    references_directory=required(options, "--references"),
    output_directory=required(options, "--output"),
    source_directory?=options.get("--source-directory"),
    seed?,
    start_step?,
    clip_ids~,
    limit=@string.parse_int(options.get("--limit").unwrap_or("8")),
  )
  println(result.stringify(indent=2))
}
