///|
fn robot_context_test_html(model : AppModel) -> String {
  let page = @rabbita.simple_cell(model~, update=(_ : Msg, model) => model, view=(
    dispatch,
    model,
  ) => render_cockpit_shell(dispatch, model))
  @rabbita.render_to_string(page)
}

///|
test "recorded robot remains selected across every workspace and section" {
  let (_, selected) = update(
    _ => @rabbita.none,
    SelectRobotContext("g1-simulation"),
    init_model(),
  )
  for view in ["operate", "robot", "tasks", "data", "diagnostics"] {
    let (_, navigated) = update(
      _ => @rabbita.none,
      SelectCockpitView(view),
      selected,
    )
    for section in cockpit_sections(view) {
      let (_, section_model) = update(
        _ => @rabbita.none,
        SelectCockpitSection(section.0),
        navigated,
      )
      assert_eq(section_model.robot_context, "g1-simulation")
      let html = robot_context_test_html(section_model)
      assert_false(html.contains("moonrobo-mesh-viewer"))
      assert_false(html.contains("Emergency Stop"))
      assert_false(html.contains("data-open-workspace-tool"))
    }
  }
}

///|
test "model and operate use the same archived viewer; E1 cannot open G1 results implicitly" {
  let recorded = { ..init_model(), robot_context: "g1-simulation", }
  assert_true(robot_context_test_html(recorded).contains("recorded-robot-slot"))
  assert_true(
    robot_context_test_html({ ..recorded, active_view: "robot", }).contains(
      "recorded-robot-slot",
    ),
  )
  let e1 = { ..init_model(), robot_context: "workspace", active_view: "data", }
  for section in ["experiments", "results", "replay"] {
    let html = robot_context_test_html({ ..e1, data_section: section, })
    assert_false(html.contains("learning-workspace-slot"))
    assert_true(html.contains("No experiments for this robot"))
  }
  let (_, rejected) = update(
    _ => @rabbita.none,
    SelectRobotContext("unknown"),
    recorded,
  )
  assert_eq(rejected.robot_context, "g1-simulation")
}
