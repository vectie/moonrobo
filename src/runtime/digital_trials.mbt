///|
/// A projection of immutable digital import and event files in the existing
/// product proof-session home. Not an execution queue or a physical receipt.
pub(all) struct DigitalTrialRecord {
  contract_id : String
  revision : Int
  import_request : @moonmoon_adapter.DigitalTrialImport
  binding : @moonmoon_adapter.DigitalTrialBinding
  events : Array[@moonmoon_adapter.DigitalTrialEvent]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct DigitalTrialView {
  record : DigitalTrialRecord
  state : String
  digital_result_state : String
  binding_state : String
  current_binding_blockers : Array[String]
  current_binding_unknowns : Array[String]
  acknowledgement_state : String
  physical_execution_allowed : Bool
  automatic_retry_allowed : Bool
  blockers : Array[String]
  unknowns : Array[String]
  retention_state : String
} derive(Debug, Eq, ToJson, FromJson)

///|
fn digital_trial_dir(root : String, trial_id : String) -> String raise {
  if !@moonmoon_adapter.digital_component(trial_id) {
    fail("Invalid digital trial identity")
  }
  moonrobo_proof_sessions_dir(root) + "/digital-trials/" + trial_id
}

///|
fn digital_write_once(path : String, text : String) -> Unit raise {
  if @fsx.path_exists(path) {
    if @fsx.read_file_to_string(path) != text {
      fail(
        "Digital evidence conflicts with persisted bytes; reopen without retry: " +
        path,
      )
    }
  } else {
    @fsx.write_string_to_file(path, text)
    if @fsx.read_file_to_string(path) != text {
      fail("Digital write acknowledgement is unknown; reopen before continuing")
    }
  }
}

///|
fn digital_acknowledgement(
  events : Array[@moonmoon_adapter.DigitalTrialEvent],
) -> String {
  let mut status = "confirmed"
  for event in events {
    if event.kind == "lost-ack" {
      status = "unknown"
    }
    if event.kind == "reconcile" {
      status = "confirmed"
    }
  }
  status
}

///|
fn validate_digital_event(
  record : DigitalTrialRecord,
  event : @moonmoon_adapter.DigitalTrialEvent,
) -> Unit raise {
  if event.trial_id != record.binding.trial_id ||
    event.expected_revision != record.revision ||
    !@moonmoon_adapter.digital_component(event.event_id) ||
    event.now_ms < 0L ||
    record.events.any(old => old.event_id == event.event_id) {
    fail("Digital event identity/revision mismatch; reopen this attempt")
  }
  if record.events.last() is Some(previous) && event.now_ms < previous.now_ms {
    fail("Digital event cannot predate its history")
  }
  match event.kind {
    "lost-ack" =>
      if digital_acknowledgement(record.events) == "unknown" ||
        event.note.trim().is_empty() ||
        event.proof_text != "" {
        fail(
          "Already unknown or missing inert acknowledgement-loss explanation",
        )
      }
    "reconcile" =>
      if digital_acknowledgement(record.events) != "unknown" ||
        event.proof_text != record.import_request.result_text ||
        event.reviewer.trim().is_empty() ||
        event.note.trim().is_empty() {
        fail(
          "Reconciliation requires the same attempt's exact digital result bytes and named review; no physical outcome is inferred",
        )
      }
    "review" =>
      if event.reviewer.trim().is_empty() ||
        event.note.trim().is_empty() ||
        event.proof_text != "" {
        fail("Incident review requires a named reviewer and note")
      }
    _ =>
      fail(
        "Unsupported inert digital event; no device operations are available",
      )
  }
}

///|
pub fn read_digital_trial(
  root : String,
  trial_id : String,
) -> DigitalTrialRecord raise {
  let dir = digital_trial_dir(root, trial_id)
  // Refuse over-limit history rather than partially validating or repairing it.
  if @fsx.read_dir(dir).length() > 130 {
    fail(
      "Retained digital history exceeds the 128-event inspection limit; evidence is truncated and was not changed",
    )
  }
  let request : @moonmoon_adapter.DigitalTrialImport = @json.from_json(
    @json.parse(@fsx.read_file_to_string(dir + "/import.json")),
  )
  if request.trial_id != trial_id {
    fail("Persisted trial identity changed")
  }
  let binding = @moonmoon_adapter.decode_digital_trial(request)
  let mut record : DigitalTrialRecord = {
    contract_id: "moonrobo.digital-trial.v1",
    revision: 0,
    import_request: request,
    binding,
    events: [],
  }
  let names = @fsx.read_dir(dir).to_array()
  let event_names = names.filter(name => {
    name.has_prefix("event-") && name.has_suffix(".json")
  })
  for index in 1..<=event_names.length() {
    let event : @moonmoon_adapter.DigitalTrialEvent = @json.from_json(
      @json.parse(
        @fsx.read_file_to_string(dir + "/event-" + index.to_string() + ".json"),
      ),
    )
    validate_digital_event(record, event)
    record = { ..record, revision: index, events: [..record.events, event], }
  }
  let head = @json.parse(@fsx.read_file_to_string(dir + "/head.json"))
  if head != digital_trial_head(record.import_request, record.events) {
    fail(
      "Digital event history does not match its last confirmed head; outcome remains unknown",
    )
  }
  record
}

///|
fn digital_trial_head(
  request : @moonmoon_adapter.DigitalTrialImport,
  events : Array[@moonmoon_adapter.DigitalTrialEvent],
) -> Json {
  {
    "revision": events.length(),
    "import_digest": @moonmoon_adapter.digital_digest(
      request.to_json().stringify(),
    ),
    "events_digest": @moonmoon_adapter.digital_digest(
      events.to_json().stringify(),
    ),
  }
}

///|
pub fn import_digital_trial(
  root : String,
  request : @moonmoon_adapter.DigitalTrialImport,
) -> DigitalTrialRecord raise {
  let _ = @moonmoon_adapter.decode_digital_trial(request)
  let dir = digital_trial_dir(root, request.trial_id)
  match ensure_process_dirs(root) {
    Ok(_) => ()
    Err(issue) => fail(issue.message)
  }
  match ensure_full_dir(moonrobo_proof_sessions_dir(root) + "/digital-trials") {
    Ok(_) => ()
    Err(issue) => fail(issue.message)
  }
  match ensure_full_dir(dir) {
    Ok(_) => ()
    Err(issue) => fail(issue.message)
  }
  let first_import = !@fsx.path_exists(dir + "/import.json")
  digital_write_once(
    dir + "/import.json",
    request.to_json().stringify(indent=2),
  )
  if first_import {
    digital_write_once(
      dir + "/head.json",
      digital_trial_head(request, []).stringify(indent=2),
    )
  }
  read_digital_trial(root, request.trial_id)
}

///|
pub fn append_digital_trial_event(
  root : String,
  event : @moonmoon_adapter.DigitalTrialEvent,
) -> DigitalTrialRecord raise {
  let record = read_digital_trial(root, event.trial_id)
  // Exact event replays acknowledge the same inert event; they never dispatch.
  for old in record.events {
    if old.event_id == event.event_id {
      if old != event {
        fail("Event identity already has different evidence")
      }
      return record
    }
  }
  if record.revision >= 128 {
    fail(
      "Retained digital history reached its 128-event inspection limit; no event was written",
    )
  }
  validate_digital_event(record, event)
  let path = digital_trial_dir(root, event.trial_id) +
    "/event-" +
    (record.revision + 1).to_string() +
    ".json"
  digital_write_once(path, event.to_json().stringify(indent=2))
  let head_path = digital_trial_dir(root, event.trial_id) + "/head.json"
  let head_text = digital_trial_head(
    record.import_request,
    [..record.events, event],
  ).stringify(indent=2)
  @fsx.write_string_to_file(head_path, head_text)
  if @fsx.read_file_to_string(head_path) != head_text {
    fail(
      "Digital event head acknowledgement is unknown; reopen before continuing",
    )
  }
  read_digital_trial(root, event.trial_id)
}

///|
fn digital_current_artifact(
  root : String,
  path : String,
  expected : String,
  label : String,
  blockers : Array[String],
  unknowns : Array[String],
) -> Unit {
  let text = @fsx.read_file_to_string(robobook_path(root, path)) catch {
    _ => {
      unknowns.push("Current local " + label + " is unavailable")
      return
    }
  }
  if @moonmoon_adapter.digital_digest(text) != expected {
    blockers.push(
      "Current local " + label + " differs from frozen MoonMoon evidence",
    )
  }
}

///|
/// Rechecks the current local files on every reopen. A local match is not
/// current calibrated hardware and never changes the existing dispatch gates.
pub fn inspect_digital_trial(
  root : String,
  trial_id : String,
) -> DigitalTrialView raise {
  let record = read_digital_trial(root, trial_id)
  let binding = record.binding
  let blockers : Array[String] = []
  let unknowns : Array[String] = []
  digital_current_artifact(
    root,
    binding.profile_path,
    binding.profile_digest,
    "robot profile",
    blockers,
    unknowns,
  )
  digital_current_artifact(
    root,
    binding.urdf_path,
    binding.urdf_digest,
    "URDF",
    blockers,
    unknowns,
  )
  digital_current_artifact(
    root,
    binding.validation_path,
    binding.validation_digest,
    "design validation",
    blockers,
    unknowns,
  )
  match binding.calibration {
    { "qualified": True, "authoritative_source": String(path), .. } =>
      digital_current_artifact(
        root,
        path,
        binding.calibration_source_digest,
        "calibration evidence",
        blockers,
        unknowns,
      )
    _ =>
      unknowns.push(
        "MoonMoon calibration is unqualified; current hardware calibration is unknown",
      )
  }
  let binding_state = if !blockers.is_empty() {
    "blocked"
  } else if !unknowns.is_empty() {
    "unknown"
  } else {
    "matched"
  }
  let current_binding_blockers = [..blockers]
  let current_binding_unknowns = [..unknowns]
  for blocker in binding.blockers {
    blockers.push(blocker)
  }
  if binding.digital_result != "accepted" && binding.blockers.is_empty() {
    blockers.push("MoonMoon digital result was rejected")
  }
  let acknowledgement_state = digital_acknowledgement(record.events)
  if acknowledgement_state == "unknown" {
    unknowns.push(
      "Inert digital import acknowledgement is unknown; reconcile the same attempt, never retry a physical action",
    )
  }
  let state = if acknowledgement_state == "unknown" {
    "unknown"
  } else if !blockers.is_empty() {
    "blocked"
  } else if !unknowns.is_empty() {
    "unknown"
  } else {
    "digital-ready"
  }
  {
    record,
    state,
    digital_result_state: if binding.digital_result == "accepted" {
      "digital-ready"
    } else {
      "blocked"
    },
    binding_state,
    current_binding_blockers,
    current_binding_unknowns,
    acknowledgement_state,
    physical_execution_allowed: false,
    automatic_retry_allowed: false,
    blockers,
    unknowns,
    retention_state: "pending-book-review",
  }
}
