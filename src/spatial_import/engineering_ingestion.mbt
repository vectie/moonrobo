///|
pub(all) struct EngineeringImportIssue {
  code : String
  message : String
} derive(Debug, Eq, ToJson)

///|
pub(all) struct EngineeringSpatialInput {
  artifact_id : String
  artifact_digest : String
  editable_parent_id : String
  editable_parent_digest : String
  payload_ref : String
  units : String
  coordinate_system : String
  up_axis : String
  handedness : String
  transform_id : String
  assumptions : Array[String]
  unresolved_gaps : Array[String]
  authority_envelope_id : String
  qualification_claimed : Bool
} derive(Debug, Eq, ToJson)

///|
fn issue(
  code : String,
  message : String,
) -> Result[EngineeringSpatialInput, EngineeringImportIssue] {
  Err({ code, message })
}

///|
fn strings(values : Array[Json]) -> Array[String]? {
  let result : Array[String] = []
  for value in values {
    match value {
      String(text) => result.push(text)
      _ => return None
    }
  }
  Some(result)
}

///|
fn valid_digest(value : String) -> Bool {
  value.has_prefix("sha256:") && value.length() == 71
}

///|
pub fn ingest_moonmold_engineering(
  text : String,
  expected_editable_parent_digest~ : String,
) -> Result[EngineeringSpatialInput, EngineeringImportIssue] {
  let parsed = @json.parse(text) catch {
    _ => return issue("invalid-json", "MoonMold envelope is not valid JSON")
  }
  match parsed {
    {
      "schema": String(schema),
      "manifest": {
        "contract_id": String(manifest_contract),
        "artifact_id": String(artifact_id),
        "representation": String(representation),
        "digest": String(artifact_digest),
        "payload_ref": String(payload_ref),
        "units": String(units),
        "coordinate_system": String(coordinate_system),
        "up_axis": String(up_axis),
        "handedness": String(handedness),
        "authority_envelope_id": String(authority_envelope_id),
        "assumptions": Array(assumption_values),
        "unresolved_gaps": Array(gap_values),
        "intended_consumers": Array(consumer_values),
        "forbidden_consumers": Array(forbidden_values),
        "claim_ceiling": String(claim_ceiling),
        ..
      },
      "transform": {
        "contract_id": String(transform_contract),
        "transform_id": String(transform_id),
        "parent_artifact_id": String(parent_artifact_id),
        "parent_digest": String(parent_digest),
        "parent_representation": String(parent_representation),
        "child_artifact_id": String(child_artifact_id),
        "child_digest": String(child_digest),
        "child_representation": String(child_representation),
        "lineage_relation": String(lineage_relation),
        "authority_ref": String(authority_ref),
        "declared_losses": Array(loss_values),
        ..
      },
      ..
    } => {
      let assumptions = match strings(assumption_values) {
        Some(value) => value
        None =>
          return issue(
            "invalid-string-array", "assumptions must contain strings",
          )
      }
      let gaps = match strings(gap_values) {
        Some(value) => value
        None =>
          return issue(
            "invalid-string-array", "unresolved gaps must contain strings",
          )
      }
      let consumers = match strings(consumer_values) {
        Some(value) => value
        None =>
          return issue("invalid-string-array", "consumers must contain strings")
      }
      let forbidden = match strings(forbidden_values) {
        Some(value) => value
        None =>
          return issue(
            "invalid-string-array", "forbidden consumers must contain strings",
          )
      }
      let losses = match strings(loss_values) {
        Some(value) => value
        None =>
          return issue(
            "invalid-string-array", "declared losses must contain strings",
          )
      }
      if schema != "moonmold-portable-ingestion-v1" ||
        manifest_contract != "moonmold.spatial-artifact.v1" ||
        transform_contract != "moonmold.representation-transform.v1" {
        return issue(
          "unsupported-contract", "portable MoonMold contract version is unsupported",
        )
      }
      if representation != "engineering-model" ||
        child_representation != "engineering-model" ||
        parent_representation != "editable-authoring-model" ||
        lineage_relation != "modeled-from" {
        return issue(
          "wrong-engineering-lane", "MoonRobo accepts only engineering models derived from editable authoring geometry",
        )
      }
      if artifact_id != child_artifact_id || artifact_digest != child_digest {
        return issue(
          "child-lineage-mismatch", "manifest and transform child identity differ",
        )
      }
      if parent_digest != expected_editable_parent_digest {
        return issue(
          "stale-editable-parent", "engineering parent is not the accepted editable model",
        )
      }
      if !valid_digest(artifact_digest) || !valid_digest(parent_digest) {
        return issue(
          "invalid-digest", "artifact and parent digests must be sha256",
        )
      }
      if !losses.is_empty() {
        return issue(
          "lossy-engineering-input", "a lossy transform cannot be promoted as engineering truth",
        )
      }
      if claim_ceiling != "digital-artifact" {
        return issue(
          "claim-ceiling-exceeded", "imported geometry is a digital candidate, not a qualified unit or physical result",
        )
      }
      if !consumers.contains("moonrobo") || forbidden.contains("moonrobo") {
        return issue(
          "consumer-policy-mismatch", "manifest does not authorize MoonRobo",
        )
      }
      if authority_envelope_id.trim().is_empty() ||
        authority_ref != authority_envelope_id {
        return issue(
          "authority-lineage-mismatch", "manifest and transform authority differ",
        )
      }
      if units.trim().is_empty() ||
        coordinate_system.trim().is_empty() ||
        up_axis.trim().is_empty() ||
        handedness.trim().is_empty() ||
        transform_id.trim().is_empty() ||
        payload_ref.trim().is_empty() {
        return issue(
          "incomplete-spatial-contract", "spatial conventions, transform, and payload are required",
        )
      }
      Ok({
        artifact_id,
        artifact_digest,
        editable_parent_id: parent_artifact_id,
        editable_parent_digest: parent_digest,
        payload_ref,
        units,
        coordinate_system,
        up_axis,
        handedness,
        transform_id,
        assumptions,
        unresolved_gaps: gaps,
        authority_envelope_id,
        qualification_claimed: false,
      })
    }
    _ =>
      issue(
        "invalid-envelope", "required portable artifact or transform fields are missing",
      )
  }
}
