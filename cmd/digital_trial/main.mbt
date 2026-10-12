///|
fn run() -> Unit raise {
  let args = @env.args()
  let response = match args[1:] {
    ["catalogue", root] =>
      @host_api.route(root, "GET", "/api/moonrobo/digital-trials")
    ["inspect", root, trial_id] =>
      @host_api.digital_trial_response(root, trial_id)
    ["import", root, path] =>
      @host_api.digital_trial_import_response(
        root,
        @fsx.read_file_to_string(path),
      )
    ["event", root, path] =>
      @host_api.digital_trial_event_response(
        root,
        @fsx.read_file_to_string(path),
      )
    ["export", root, trial_id] =>
      @host_api.digital_trial_export_response(
        root,
        ({ "trial_id": trial_id } : Json).stringify(),
      )
    _ =>
      fail(
        "Usage: digital_trial catalogue <robobook-root> | import <root> <request.json> | inspect <root> <trial-id> | event <root> <event.json> | export <root> <trial-id>. Digital evidence only; no device operations.",
      )
  }
  println(response.body)
  if response.status != 200 {
    @sys.exit(1)
  }
}

///|
fn main {
  run() catch {
    error => {
      let diagnostic : Json = {
        "code": "digital-trial-cli-unconfirmed",
        "message": error.to_string(),
        "physical_execution_allowed": false,
      }
      println(diagnostic.stringify(indent=2))
      @sys.exit(1)
    }
  }
}
