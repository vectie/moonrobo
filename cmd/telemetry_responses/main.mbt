///|
let usage : String =
  #|telemetry_responses INPUT.csv RECIPE.json [--format json|csv|summary-csv|svg|clip-csv] [--clip-episode INDEX]
  #|Align explicitly selected observed threshold episodes within one recording.
  #|The editable recipe declares channels, units, episodes, pre/post window, grid,
  #|event/interpolation gap limits and overlap policy. See docs/offline-event-responses.md.
  #|JSON includes full recorded source values, recipe hashes, brackets and missing support.
  #|csv/summary-csv are review tables, not raw telemetry. clip-csv preserves original rows.
  #|Recorded-data exploration only; no device access, physical proof or command authority.

///|
fn run(args : Array[String]) -> Unit raise {
  if args.length() == 2 && (args[1] == "--help" || args[1] == "-h") {
    println(usage)
    return
  }
  guard args.length() >= 3 else { fail(usage) }
  let mut format = "json"
  let mut clip_episode : Int? = None
  let seen : Array[String] = []
  for i = 3; i < args.length(); {
    let flag = args[i]
    if seen.contains(flag) {
      fail("duplicate option: " + flag)
    }
    seen.push(flag)
    guard flag == "--format" || flag == "--clip-episode" else {
      fail("unknown option: " + flag)
    }
    guard i + 1 < args.length() else { fail("missing value for " + flag) }
    if flag == "--format" {
      format = args[i + 1]
    } else {
      clip_episode = Some(
        @string.parse_int(args[i + 1]) catch {
          _ => fail("invalid episode index")
        },
      )
    }
    continue i + 2
  }
  if !["json", "csv", "summary-csv", "svg", "clip-csv"].contains(format) {
    fail("format must be json, csv, summary-csv, svg or clip-csv")
  }
  if (format == "clip-csv") != (clip_episode is Some(_)) {
    fail("--clip-episode is required only with --format clip-csv")
  }
  let bytes = @fsx.read_file_to_bytes(args[1])
  let text = @utf8.decode(bytes) catch {
    _ => fail("input must be valid UTF-8")
  }
  let recipe_bytes = @fsx.read_file_to_bytes(args[2])
  let recipe_text = @utf8.decode(recipe_bytes) catch {
    _ => fail("recipe must be valid UTF-8")
  }
  let recipe = match @telemetry.parse_event_response_recipe(recipe_text) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  let report = match
    @telemetry.event_responses_csv(
      text,
      recipe.event_channel,
      recipe.direction,
      recipe.threshold,
      episodes=recipe.episodes,
      channels=recipe.channels,
      unit_labels=recipe.unit_labels,
      before_ms=recipe.before_ms,
      after_ms=recipe.after_ms,
      step_ms=recipe.step_ms,
      event_min_span_ms=recipe.event_min_span_ms,
      event_max_gap_ms=recipe.event_max_gap_ms,
      max_gap_ms=recipe.max_gap_ms,
      overlap_policy=recipe.overlap_policy,
    ) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  let output = match format {
    "csv" => report.to_csv()
    "summary-csv" => report.summary_csv()
    "svg" =>
      match report.to_svg() {
        Ok(value) => value
        Err(message) => fail(message)
      }
    "clip-csv" =>
      match report.clip_csv(clip_episode.unwrap()) {
        Ok(value) => value
        Err(message) => fail(message)
      }
    _ =>
      (
        {
          "format": "moonrobo.recorded-event-response-file.v1",
          "input_file": args[1].to_json(),
          "source_sha256": @crypto.bytes_to_hex_string(@crypto.sha256(bytes)).to_json(),
          "recipe_file": args[2].to_json(),
          "recipe_sha256": @crypto.bytes_to_hex_string(
            @crypto.sha256(recipe_bytes),
          ).to_json(),
          "recipe": recipe.to_json(),
          "response": report.to_json(),
        } : Json).stringify(indent=2)
  }
  println(output.trim_end())
}

///|
fn main {
  run(@env.args()) catch {
    error => {
      eprintln(({ "error": error.to_string() } : Json).stringify())
      @sys.exit(2)
    }
  }
}
