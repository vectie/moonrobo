///|
async fn main {
  let args = @env.args()[1:]
  guard args.length() == 6 || args.length() == 7 else {
    fail(
      "usage: e1_live_actor_shadow BUNDLE CANN_LIBRARY MODEL_OM READONLY_STATUS_PLUGIN CONFIG_JSON NEW_REPORT_JSON [PREPARED_REFERENCE_JSON]",
    )
  }
  guard args[:6]
    is [
      directory,
      cann,
      model,
      readonly_status_plugin,
      configuration_path,
      output,
    ] else {
    fail(
      "usage: e1_live_actor_shadow BUNDLE CANN_LIBRARY MODEL_OM READONLY_STATUS_PLUGIN CONFIG_JSON NEW_REPORT_JSON",
    )
  }
  guard !@fs.exists(output) else { fail("report path must be new") }
  let bundle = @actor.Bundle::read(directory)
  let reference = match args.get(6) {
    Some(path) => Some(@reference.Clip::read(bundle, path))
    None => None
  }
  let configuration : Configuration = @json.from_json(
    @fs.read_file(configuration_path).json(),
  )
  validate_configuration(bundle, configuration)
  let actor = @actor.Actor::open_ascend(bundle, cann, model)
  defer (actor.close() catch {
    error => println("Ascend close failed: " + error.to_string())
  })
  // Select the reviewed read-only status adapter. No vendor control object or
  // motor/mode writer is created by that adapter. Its DDS reader is process-owned.
  let controller = @low.Controller::open(readonly_status_plugin)
  run_shadow(bundle, actor, controller, configuration, output, reference~)
  actor.close()
}
