///|
pub(all) struct DigitalPhysicalMapping {
  mapping_id : String
  robobook_root : String
  robot_id : @core.RobotId
  resident_id : String
  town_route : String
  bridge_id : @core.BridgeId
  bridge_state : String
  runtime_status : String
  runtime_bridge_base_url : String
  availability : String
  mapped : Bool
  reachable : Bool
  latest_task_id : String
  latest_execution_status : String
  latest_feedback_status : String
  latest_command_outcome_status : String
  verified_execution_count : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
fn mapping_reachable(
  agent : ResidentRobotAgent,
  runtime_status : String,
) -> Bool {
  runtime_status == "healthy" ||
  runtime_status == "running" ||
  agent.bridge_state == "launchable"
}

///|
pub fn digital_physical_mapping(
  book : @runtime.LoadedRoboBook,
  agent : ResidentRobotAgent,
  runtime_status? : String = "unknown",
  runtime_bridge_base_url? : String = "",
) -> DigitalPhysicalMapping {
  let latest = agent.latest_execution
  {
    mapping_id: "mapping:\{book.profile.id}",
    robobook_root: book.root,
    robot_id: book.profile.id,
    resident_id: agent.resident_id,
    town_route: agent.town_route,
    bridge_id: book.profile.bridge.id,
    bridge_state: agent.bridge_state,
    runtime_status,
    runtime_bridge_base_url,
    availability: agent.availability,
    mapped: book.profile.id != "" &&
    agent.resident_id == resident_id(book.profile) &&
    book.profile.bridge.id != "",
    reachable: mapping_reachable(agent, runtime_status),
    latest_task_id: match latest {
      Some(execution) => execution.task_id
      None => ""
    },
    latest_execution_status: match latest {
      Some(execution) => execution.status
      None => "missing"
    },
    latest_feedback_status: match latest {
      Some(execution) => execution.physical_feedback_status
      None => "missing"
    },
    latest_command_outcome_status: match latest {
      Some(execution) => execution.command_outcome_status
      None => "missing"
    },
    verified_execution_count: agent.verified_execution_count,
  }
}
