///|
fn optional_evidence(value : Json, key : String) -> Json {
  match value {
    Object(fields) => fields.get(key).unwrap_or(Json::null())
    _ => Json::null()
  }
}

///|
/// Only native result fields with a defined unit are projected. Missing,
/// nonnumeric and nonfinite values remain unavailable, never coerced to zero.
fn digital_metric(
  result : Json,
  key : String,
  label : String,
  unit : String,
) -> Json {
  let value = match optional_evidence(result, key) {
    Number(number, ..) if number == number && number - number == 0 =>
      number.to_json()
    _ => Json::null()
  }
  {
    "key": key,
    "label": label,
    "unit": unit,
    "value": value,
    "available": value != Json::null(),
  }
}

///|
/// Called only after the complete frozen dossier/result/design/provenance and
/// replay bindings have passed decode_digital_trial. No simulation is performed.
fn digital_frozen_evidence(
  result : Json,
  alternative : Json,
  replay : Json,
  provenance : Json,
  baseline_digest : String,
) -> Json {
  let metrics : Array[Json] = []
  for
    (key, label, unit) in [
      ("distance_m", "Distance", "m"),
      ("duration_s", "Duration", "s"),
      (
        "maximum_measured_segment_slope_deg", "Maximum measured segment slope", "deg",
      ),
      ("waypoint_count", "Waypoints", "count"),
      ("delivery_count", "Deliveries", "count"),
    ] {
    metrics.push(digital_metric(result, key, label, unit))
  }
  let energy = optional_evidence(result, "energy")
  for
    (key, label) in [
      ("required_wh", "Required energy"),
      ("available_wh", "Available energy"),
      ("margin_wh", "Energy margin"),
    ] {
    metrics.push(digital_metric(energy, key, label, "Wh"))
  }
  {
    "contract_id": "moonrobo.frozen-digital-evidence.v1",
    "baseline_verified": true,
    "baseline_digest": baseline_digest,
    "scenario_id": optional_evidence(result, "scenario_id"),
    "scenario_kind": optional_evidence(result, "scenario_kind"),
    "scenario_outcome": optional_evidence(result, "scenario_outcome"),
    "seed": optional_evidence(result, "seed"),
    "route_id": optional_evidence(result, "route_id"),
    "final_state": optional_evidence(result, "final_state"),
    "evidence_claim": optional_evidence(result, "evidence_claim"),
    "whole_grid_status": optional_evidence(result, "whole_grid_status"),
    "metrics": metrics.to_json(),
    "design_ref": optional_evidence(alternative, "design_ref"),
    "result_ref": optional_evidence(alternative, "result_ref"),
    "provenance_ref": optional_evidence(alternative, "provenance_ref"),
    "replay_ref": optional_evidence(alternative, "replay_ref"),
    "replay_required": optional_evidence(replay, "required_replays"),
    "replay_completed": optional_evidence(replay, "completed_replays"),
    "replay_byte_equivalent": optional_evidence(replay, "byte_equivalent"),
    "provenance_source_digests": optional_evidence(provenance, "source_digests"),
    "physical_execution_allowed": false,
  }
}
