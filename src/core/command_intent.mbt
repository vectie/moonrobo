///|
pub(all) struct Requester {
  kind : String
  id : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct CommandIntent {
  intent_id : IntentId
  robot_id : RobotId
  capability : CapabilityId
  parameters : Map[String, String]
  requested_by : Requester
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn operator_requester(id : String) -> Requester {
  { kind: "operator", id }
}

///|
pub fn moontown_requester(id : String) -> Requester {
  { kind: "moontown", id }
}

///|
pub fn command_intent(
  intent_id : IntentId,
  robot_id : RobotId,
  capability : CapabilityId,
  requested_by : Requester,
  parameters? : Map[String, String] = {},
) -> CommandIntent {
  { intent_id, robot_id, capability, parameters, requested_by }
}
