///|
pub(all) struct SdkE1HighControlCommand {
  intent_id : String
  capability : String
  action : String
  action_code : Int
  vertical : Double
  horizontal : Double
  duration_ms : Int
  data : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
fn parse_double_parameter(
  parameters : Map[String, String],
  key : String,
  fallback : String,
) -> Result[Double, SdkE1AdapterIssue] {
  let text = parameters.get(key).unwrap_or(fallback)
  let value = @string.parse_double(text) catch {
    _ =>
      return Err(
        issue(
          "invalid-high-control-parameter",
          "SDK E1 high-control parameter `\{key}` must be a number",
        ),
      )
  }
  Ok(value)
}

///|
fn parse_int_parameter(
  parameters : Map[String, String],
  key : String,
  fallback : String,
) -> Result[Int, SdkE1AdapterIssue] {
  let text = parameters.get(key).unwrap_or(fallback)
  let value = @string.parse_int(text) catch {
    _ =>
      return Err(
        issue(
          "invalid-high-control-parameter",
          "SDK E1 high-control parameter `\{key}` must be an integer",
        ),
      )
  }
  Ok(value)
}

///|
fn command(
  intent : @core.CommandIntent,
  action : String,
  action_code : Int,
  vertical : Double,
  horizontal : Double,
  duration_ms : Int,
  data? : Int = 0,
) -> SdkE1HighControlCommand {
  {
    intent_id: intent.intent_id,
    capability: intent.capability,
    action,
    action_code,
    vertical,
    horizontal,
    duration_ms,
    data,
  }
}

///|
pub fn high_control_command(
  intent : @core.CommandIntent,
) -> Result[SdkE1HighControlCommand, SdkE1AdapterIssue] {
  match intent.capability {
    "control.high.walk" => {
      let vertical = match
        parse_double_parameter(intent.parameters, "x", "0.0") {
        Ok(value) => value
        Err(issue) => return Err(issue)
      }
      let horizontal = match
        parse_double_parameter(intent.parameters, "yaw", "0.0") {
        Ok(value) => value
        Err(issue) => return Err(issue)
      }
      let duration_ms = match
        parse_int_parameter(intent.parameters, "duration_ms", "1000") {
        Ok(value) => value
        Err(issue) => return Err(issue)
      }
      Ok(command(intent, "WALK", 0, vertical, horizontal, duration_ms))
    }
    "control.high.run" => {
      let vertical = match
        parse_double_parameter(intent.parameters, "x", "0.0") {
        Ok(value) => value
        Err(issue) => return Err(issue)
      }
      let horizontal = match
        parse_double_parameter(intent.parameters, "yaw", "0.0") {
        Ok(value) => value
        Err(issue) => return Err(issue)
      }
      let duration_ms = match
        parse_int_parameter(intent.parameters, "duration_ms", "800") {
        Ok(value) => value
        Err(issue) => return Err(issue)
      }
      Ok(command(intent, "RUN", 4, vertical, horizontal, duration_ms))
    }
    _ =>
      Err(
        issue(
          "unsupported-high-control", "SDK E1 high-control bridge only supports allowlisted walk/run intents",
        ),
      )
  }
}

///|
pub fn high_control_command_summary(
  command : SdkE1HighControlCommand,
) -> String {
  "sdk-e1 high-control \{command.action} vertical=\{command.vertical} horizontal=\{command.horizontal} duration_ms=\{command.duration_ms}"
}

///|
pub fn high_control_command_artifact(
  command : SdkE1HighControlCommand,
) -> String {
  "sdk-e1://high-control/\{command.action}?vertical=\{command.vertical}&horizontal=\{command.horizontal}&duration_ms=\{command.duration_ms}&data=\{command.data}"
}
