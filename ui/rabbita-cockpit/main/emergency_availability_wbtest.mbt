///|
// These tests construct deferred commands only. No command is executed and no
// network, runtime supervisor, bridge, or physical device is contacted.
extern "js" fn same_command(a : Cmd, b : Cmd) -> Bool = "(a, b) => a === b"

///|
fn emergency_test_html(model : AppModel, bridge? : Bool = false) -> String {
  let page = @rabbita.simple_cell(model~, update=(_ : Msg, model) => model, view=(
    dispatch,
    model,
  ) => {
    if bridge {
      render_bridge(dispatch, model)
    } else {
      render_cockpit_header(dispatch, model)
    }
  })
  @rabbita.render_to_string(page)
}

///|
fn emergency_button_is_disabled(html : String) -> Bool {
  for part in html.split("<button") {
    let button = part.split("</button>").collect()[0]
    if button.contains("Emergency Stop") || button.contains("Stopping Now...") {
      return button.contains("disabled")
    }
  }
  abort("Emergency stop button missing")
}

///|
test "emergency stop stays available during slow snapshot reads in both views" {
  let loading = { ..init_model(), loading: true, }
  assert_false(emergency_button_is_disabled(emergency_test_html(loading)))
  assert_false(
    emergency_button_is_disabled(emergency_test_html(loading, bridge=true)),
  )
  let (command, pending) = update(
    _ => @rabbita.none,
    EmergencyStopRuntime,
    loading,
  )
  assert_false(same_command(command, @rabbita.none))
  assert_true(pending.loading)
  assert_true(pending.stopping_emergency)
  assert_true(emergency_button_is_disabled(emergency_test_html(pending)))
  assert_true(
    emergency_button_is_disabled(emergency_test_html(pending, bridge=true)),
  )
  assert_true(emergency_test_html(pending).contains("Sending emergency stop"))
  let (duplicate, still_pending) = update(
    _ => @rabbita.none,
    EmergencyStopRuntime,
    pending,
  )
  assert_true(same_command(duplicate, @rabbita.none))
  assert_true(still_pending.stopping_emergency)
  // Completion of an unrelated read cannot unlock a pending stop request.
  let (_, refreshed) = update(
    _ => @rabbita.none,
    SnapshotLoaded(Err("fixture read timeout")),
    still_pending,
  )
  assert_false(refreshed.loading)
  assert_true(emergency_button_is_disabled(emergency_test_html(refreshed)))
}

///|
test "emergency completion stays visible and retryable through refreshes" {
  let (_, pending) = update(_ => @rabbita.none, EmergencyStopRuntime, {
    ..init_model(),
    loading: true,
  })
  let (_, stopped) = update(
    _ => @rabbita.none,
    RuntimeEmergencyStopped(
      Ok(command_result("Emergency stop Executed: fixture receipt")),
    ),
    pending,
  )
  assert_true(stopped.loading)
  assert_false(stopped.stopping_emergency)
  assert_false(emergency_button_is_disabled(emergency_test_html(stopped)))
  assert_true(
    emergency_test_html(stopped).contains(
      "Emergency stop Executed: fixture receipt",
    ),
  )
  // An unrelated runtime response must not overwrite the emergency result.
  let (_, other_runtime) = update(
    _ => @rabbita.none,
    RuntimeStarted(Err("fixture runtime rejected")),
    stopped,
  )
  assert_true(
    emergency_test_html(other_runtime).contains(
      "Emergency stop Executed: fixture receipt",
    ),
  )
  let (_, failed) = update(
    _ => @rabbita.none,
    RuntimeEmergencyStopped(Err("fixture transport timeout")),
    pending,
  )
  assert_true(failed.loading)
  assert_false(failed.stopping_emergency)
  assert_false(emergency_button_is_disabled(emergency_test_html(failed)))
  assert_true(
    emergency_test_html(failed).contains(
      "Emergency stop rejected: fixture transport timeout",
    ),
  )
  let (retry, retrying) = update(
    _ => @rabbita.none,
    EmergencyStopRuntime,
    failed,
  )
  assert_false(same_command(retry, @rabbita.none))
  assert_true(retrying.stopping_emergency)
}
