///|
fn safe_health_suffix(value : String) -> String {
  value
  .replace(old=":", new="-")
  .replace(old="/", new="-")
  .replace(old=" ", new="-")
}

///|
fn health_operation_refs(
  report : @suite_adapter.AdapterReadiness,
) -> Array[String] {
  report.operations
  .filter(operation => operation.ready)
  .map(operation => {
    "moonrobo/\{operation.operation_id}@\{@suite_adapter.pack_version()}"
  })
}

///|
pub fn health_attestation(
  workspace_root : String,
  robobook_ref : String,
  checked_at : String,
  valid_until : String,
) -> Result[@suite_adapter.AdapterHealthAttestation, AdapterRuntimeIssue] {
  let report = readiness(workspace_root, robobook_ref)
  let operation_refs = health_operation_refs(report)
  let evidence_ref = ".moonsuite/products/moonrobo/adapter-health/\{@suite_adapter.adapter_id()}-\{safe_health_suffix(checked_at)}.json"
  let evidence_path = match resolve_ref(workspace_root, evidence_ref) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let parent = evidence_path[:evidence_path.rev_find("/").unwrap_or(0)].to_owned()
  match ensure_directory_tree(parent) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let evidence : Json = {
    "contract_id": "moonrobo.adapter-health-evidence.v1",
    "adapter_id": @suite_adapter.adapter_id(),
    "pack_version": @suite_adapter.pack_version(),
    "protocol": @suite_adapter.adapter_protocol(),
    "checked_at": checked_at,
    "valid_until": valid_until,
    "operation_refs": operation_refs,
    "capability": @suite_adapter.moonflow_adapter_capability_json_with_health(
      report.healthy,
    ),
    "readiness": report,
  }
  let evidence_text = evidence.stringify(indent=2) + "\n"
  @fsx.write_string_to_file(evidence_path, evidence_text) catch {
    _ =>
      return Err(
        issue(
          "write-adapter-health", evidence_path, "failed to persist adapter health evidence",
        ),
      )
  }
  Ok({
    contract_id: "moonflow.adapter-health.v1",
    adapter_id: @suite_adapter.adapter_id(),
    product_id: "moonrobo",
    pack_id: "moonrobo",
    pack_version: @suite_adapter.pack_version(),
    protocol: @suite_adapter.adapter_protocol(),
    status: if report.healthy && !operation_refs.is_empty() {
      "healthy"
    } else {
      "unhealthy"
    },
    checked_at,
    valid_until,
    operation_refs,
    evidence_ref,
    evidence_digest: @moondata_core.text_checksum(evidence_text),
  })
}

///|
pub fn capability_source_bundle(
  pack_manifest : Json,
  workspace_root : String,
  robobook_ref : String,
  compiled_at : String,
  valid_until : String,
) -> Result[Json, AdapterRuntimeIssue] {
  let health = match
    health_attestation(workspace_root, robobook_ref, compiled_at, valid_until) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    "contract_id": "moonflow.capability-source-bundle.v1",
    "catalog_id": "moonrobo-\{safe_health_suffix(compiled_at)}",
    "compiled_at": compiled_at,
    "pack_manifests": [pack_manifest],
    "adapter_declarations": [@suite_adapter.adapter_declaration_json()],
    "health_attestations": [health],
  })
}
