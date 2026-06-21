///|
/// Entry point for the CLI or runnable program in this template.
/// Keep main focused; move logic into the library package.
/// Run with `moon run cmd/main` from the project root.
fn main {
  let profile = @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01")
  let report = @core.validate_robot_profile(profile)
  if report.valid {
    let bridge = @mock_bridge.new(profile)
    let frame = @mock_bridge.telemetry_frame(profile, bridge, 0L)
    let intent = @pipeline.observe_telemetry_intent(
      "intent-cli-observe",
      profile.id,
      @core.operator_requester("cli"),
    )
    let result = @pipeline.evaluate_request(
      profile,
      @mock_bridge.health(profile),
      intent,
      "receipt-cli-observe",
      0L,
    )
    if result.next_action == Execute {
      println(
        "Moonrobo ready: \{profile.label}; mock telemetry joints=\{frame.joints.length()}",
      )
    } else {
      println("Moonrobo ready but pipeline did not allow observation")
    }
  } else {
    println("Moonrobo core profile invalid: \{report.issues.length()} issue(s)")
  }
}
