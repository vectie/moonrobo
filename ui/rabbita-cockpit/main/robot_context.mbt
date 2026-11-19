///|
#cfg(target="js")
extern "js" fn initial_robot_context() -> String =
  #| () => globalThis.__MOONROBO_ROBOT_CONTEXT || 'workspace'

///|
#cfg(not(target="js"))
fn initial_robot_context() -> String {
  "workspace"
}

///|
#cfg(target="js")
extern "js" fn persist_robot_context(value : String) =
  #| value => globalThis.__moonroboRememberRobot?.(value)

///|
#cfg(not(target="js"))
fn persist_robot_context(_value : String) -> Unit {
  ()
}

///|
fn remember_robot_context(value : String) -> @rabbita.Cmd {
  @cmd.custom_cmd(_ => persist_robot_context(value), kind=@cmd.after_render)
}

///|
fn render_robot_selector(
  dispatch : @rabbita.Emit[Msg],
  model : AppModel,
) -> Html {
  @html.select(
    id="workspace-robot",
    class="robot-switch",
    title="Robot",
    attrs=@html.Attrs::build().aria_label("Robot"),
    on_change=value => dispatch(SelectRobotContext(value)),
    [
      @html.option(
        value="g1-simulation",
        selected=model.robot_context == "g1-simulation",
        "Unitree G1",
      ),
      @html.option(
        value="workspace",
        selected=model.robot_context == "workspace",
        model.snapshot.robot.label,
      ),
    ],
  )
}

///|
fn render_robot_empty(
  dispatch : @rabbita.Emit[Msg],
  recorded~ : Bool,
  title~ : String = "No connected controls",
) -> Html {
  div(class="robot-context-empty", [
    robo_glyph(if recorded { "connection" } else { "history" }),
    h2(if recorded { title } else { "No experiments for this robot" }),
    p(
      if recorded {
        "Unitree G1 · recorded simulation"
      } else {
        "Recordings are available for Unitree G1."
      },
    ),
    button(
      class="lw-primary",
      type_="button",
      on_click=dispatch(
        SelectRobotContext(if recorded { "workspace" } else { "g1-simulation" }),
      ),
      if recorded {
        "Switch to workspace robot"
      } else {
        "View Unitree G1"
      },
    ),
  ])
}

///|
fn render_recorded_robot(dispatch : @rabbita.Emit[Msg]) -> Html {
  div(class="recorded-robot-panel", [
    div(class="recorded-robot-toolbar", [
      button(
        class="lw-primary",
        type_="button",
        on_click=dispatch(OpenRobotReplay),
        [robo_glyph("history"), span("Open replay")],
      ),
    ]),
    div(id="recorded-robot-slot", ([] : Array[Html])),
  ])
}
