///|
/// These direct handlers read/write inert local evidence only. They never call
/// bridge, SDK, grant, task execution, Book storage or provider operations.
pub fn digital_trial_response(
  root : String,
  trial_id : String,
) -> HostApiResponse {
  let view = @runtime.inspect_digital_trial(root, trial_id) catch {
    error =>
      return error_response(
        409,
        "digital-trial-unconfirmed",
        trial_id,
        error.to_string(),
      )
  }
  json_response(200, view.to_json())
}

///|
pub fn digital_trial_import_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let request : @moonmoon_adapter.DigitalTrialImport = @json.from_json(
    @json.parse(body),
  ) catch {
    error =>
      return error_response(
        400,
        "digital-trial-import",
        "/api/moonrobo/digital-trials/import",
        error.to_string(),
      )
  }
  let _ = @runtime.import_digital_trial(root, request) catch {
    error =>
      return error_response(
        409,
        "digital-trial-import-unconfirmed",
        request.trial_id,
        error.to_string(),
      )
  }
  digital_trial_response(root, request.trial_id)
}

///|
pub fn digital_trial_event_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let event : @moonmoon_adapter.DigitalTrialEvent = @json.from_json(
    @json.parse(body),
  ) catch {
    error =>
      return error_response(
        400,
        "digital-trial-event",
        "/api/moonrobo/digital-trials/event",
        error.to_string(),
      )
  }
  let _ = @runtime.append_digital_trial_event(root, event) catch {
    error =>
      return error_response(
        409,
        "digital-trial-event-unconfirmed",
        event.trial_id,
        error.to_string(),
      )
  }
  digital_trial_response(root, event.trial_id)
}

///|
pub fn digital_trial_export_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let request = @json.parse(body) catch {
    error =>
      return error_response(
        400,
        "digital-trial-export",
        "/api/moonrobo/digital-trials/export",
        error.to_string(),
      )
  }
  guard request is { "trial_id": String(trial_id), .. } else {
    return error_response(
      400, "digital-trial-export", "", "Export requires trial_id",
    )
  }
  let record = @runtime.read_digital_trial(root, trial_id) catch {
    error =>
      return error_response(
        409,
        "digital-trial-export",
        trial_id,
        error.to_string(),
      )
  }
  let packet = @moonbook.digital_incident_export(
    record.import_request,
    record.binding,
    record.events,
  ) catch {
    error =>
      return error_response(
        409,
        "digital-trial-review-required",
        trial_id,
        error.to_string(),
      )
  }
  json_response(200, packet)
}
