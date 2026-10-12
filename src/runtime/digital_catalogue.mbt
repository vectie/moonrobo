///|
fn digital_unavailable_entry(id : String, state : String) -> Json {
  {
    "trial_id": id,
    "state": state,
    "selectable": false,
    "message": "Retained evidence is " + state + "; no repair was attempted.",
  }
}

///|
fn digital_catalogue_entry(root : String, id : String) -> Json {
  if !@moonmoon_adapter.digital_component(id) {
    return digital_unavailable_entry(id, "invalid-name")
  }
  let dir = digital_trial_dir(root, id) catch {
    _ => return digital_unavailable_entry(id, "invalid-name")
  }
  if !@fsx.path_exists(dir + "/import.json") ||
    !@fsx.path_exists(dir + "/head.json") {
    return digital_unavailable_entry(id, "missing-evidence")
  }
  let names = @fsx.read_dir(dir) catch {
    _ => return digital_unavailable_entry(id, "unreadable")
  }
  if names.length() > 130 {
    return digital_unavailable_entry(id, "truncated-history")
  }
  let record = read_digital_trial(root, id) catch {
    _ => return digital_unavailable_entry(id, "invalid-evidence")
  }
  {
    "trial_id": id,
    "state": "verified",
    "selectable": true,
    "message": "",
    "session_id": record.binding.session_id,
    "digital_result": record.binding.digital_result,
    "robot_id": record.binding.robot_id,
    "robot_revision": record.binding.robot_revision,
    "revision": record.revision,
    "acknowledgement_state": digital_acknowledgement(record.events),
    "result_digest": record.binding.result_digest,
    "baseline_digest": record.binding.baseline_digest,
  }
}

///|
/// Read-only discovery, lexical order, at most 32 verified summaries and 128
/// events per trial. Directory names are enumerated first, not streamed. No
/// root initialization, source repair, execution, replay or Book operation.
pub fn digital_trial_catalogue(root : String) -> Json {
  let path = moonrobo_proof_sessions_dir(root) + "/digital-trials"
  let entries : Array[Json] = []
  let mut state = "missing"
  let mut truncated = false
  if @fsx.path_exists(path) {
    let names = @fsx.read_dir(path).to_owned() catch {
      _ =>
        return {
          "contract_id": "moonrobo.digital-trial-catalogue.v1",
          "state": "unreadable",
          "entries": [],
          "limit": 32,
          "truncated": false,
          "physical_execution_allowed": false,
        }
    }
    names.sort()
    truncated = names.length() > 32
    state = if truncated {
      "truncated"
    } else if names.is_empty() {
      "empty"
    } else {
      "available"
    }
    for id in names[:32] {
      entries.push(digital_catalogue_entry(root, id))
    }
  }
  {
    "contract_id": "moonrobo.digital-trial-catalogue.v1",
    "state": state,
    "entries": entries.to_json(),
    "limit": 32,
    "truncated": truncated,
    "physical_execution_allowed": false,
  }
}
