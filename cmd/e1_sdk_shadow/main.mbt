///|
async fn main {
  let args = @env.args()[1:]
  guard args is [_, directory, ..] else {
    fail(
      "usage: e1_sdk_shadow reference BUNDLE SDK_PLUGIN SESSION_JSON TASK_BIND | ascend BUNDLE CANN_LIBRARY MODEL_OM SDK_PLUGIN SESSION_JSON TASK_BIND",
    )
  }
  let bundle = @actor.Bundle::read(directory)
  let (actor, sdk_plugin, configuration, bind) = match args {
    ["reference", _, sdk, configuration, bind] => {
      let bytes = @fs.read_file(directory + "/parameters.f32").binary()
      (@actor.Actor::reference(bundle, bytes[:]), sdk, configuration, bind)
    }
    ["ascend", _, cann, model, sdk, configuration, bind] =>
      (@actor.Actor::open_ascend(bundle, cann, model), sdk, configuration, bind)
    _ => fail("invalid SDK shadow command")
  }
  defer (actor.close() catch { _ => () })
  let plan = @shadow.Plan::read(actor, configuration)
  let address = @socket.Addr::parse(bind)
  let controller = @low.Controller::open(sdk_plugin)
  let host = plan.host(
    controller,
    clock=() => @env.now().reinterpret_as_int64(),
    record=value => println(value.stringify()),
    stopped=() => println("{\"published\":false,\"software_stopped\":true}"),
  )
  let server = @http.Server(address)
  defer server.close()
  println(
    "E1 SDK shadow task service at \{server.addr}; SDK inputs, command recording only, published=false",
  )
  host.serve(server)
}
