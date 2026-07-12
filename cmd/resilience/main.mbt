///|
async fn execute(input_path : String, output_path : String) -> String {
  let input = @fs.read_file(input_path).text() catch {
    error =>
      return (
        { "accepted": false, "error": "cannot read plan: \{error}" } : Json).stringify(
        indent=2,
      )
  }
  let plan : @resilience_model.RobotResiliencePlan = @json.from_json(
    @json.parse(input),
  ) catch {
    error =>
      return ({ "accepted": false, "error": "invalid plan: \{error}" } : Json).stringify(
        indent=2,
      )
  }
  match @resilience_model.qualify_resilience_plan(plan) {
    Err(error) =>
      ({ "accepted": false, "error": error } : Json).stringify(indent=2)
    Ok(report) => {
      let rendered = report.to_json().stringify(indent=2) + "\n"
      @fs.write_file(
        output_path,
        @encoding/utf8.encode(rendered),
        create=0o644,
        truncate=true,
      ) catch {
        error =>
          return (
            {
              "accepted": false,
              "error": "cannot write qualification: \{error}",
            } : Json).stringify(indent=2)
      }
      rendered
    }
  }
}

///|
async fn main {
  match @env.args()[1:] {
    [input_path, output_path] => println(execute(input_path, output_path))
    _ => println("moon run cmd/resilience -- <plan.json> <qualification.json>")
  }
}
