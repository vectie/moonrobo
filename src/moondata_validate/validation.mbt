///|
pub(all) struct ValidationFinding {
  rule_id : String
  severity : String
  artifact_kind : String
  artifact_id : String
  message : String
  recommendation : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ValidationReport {
  root : String
  generated_at_ms : Int64
  status : String
  catalog_entry_count : Int
  finding_count : Int
  blocker_count : Int
  warning_count : Int
  findings : Array[ValidationFinding]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn validation_finding(
  rule_id : String,
  severity : String,
  artifact_kind : String,
  artifact_id : String,
  message : String,
  recommendation? : String = "",
) -> ValidationFinding {
  { rule_id, severity, artifact_kind, artifact_id, message, recommendation }
}

///|
fn count_severity(
  findings : Array[ValidationFinding],
  severity : String,
) -> Int {
  let mut count = 0
  for finding in findings {
    if finding.severity == severity {
      count += 1
    }
  }
  count
}

///|
fn duplicate_key(entry : @moondata_core.CatalogEntry) -> String {
  "\{entry.artifact_kind}:\{entry.artifact_id}"
}

///|
fn add_entry_shape_findings(
  findings : Array[ValidationFinding],
  entry : @moondata_core.CatalogEntry,
) -> Unit {
  if entry.artifact_kind == "" {
    findings.push(
      validation_finding(
        "catalog-entry-kind-required",
        "blocker",
        "catalog-entry",
        entry.artifact_id,
        "catalog entry has no artifact_kind",
        recommendation="write catalog entries with explicit MoonData artifact kinds",
      ),
    )
  }
  if entry.artifact_id == "" {
    findings.push(
      validation_finding(
        "catalog-entry-id-required",
        "blocker",
        entry.artifact_kind,
        "",
        "catalog entry has no artifact_id",
        recommendation="write catalog entries with stable MoonData artifact ids",
      ),
    )
  }
  if entry.manifest_path == "" {
    findings.push(
      validation_finding(
        "catalog-entry-path-required",
        "blocker",
        entry.artifact_kind,
        entry.artifact_id,
        "catalog entry has no manifest_path",
        recommendation="point catalog entries to durable MoonData manifests",
      ),
    )
  }
}

///|
fn add_duplicate_findings(
  findings : Array[ValidationFinding],
  entries : Array[@moondata_core.CatalogEntry],
) -> Unit {
  for i in 0..<entries.length() {
    for j in (i + 1)..<entries.length() {
      if duplicate_key(entries[i]) == duplicate_key(entries[j]) {
        findings.push(
          validation_finding(
            "duplicate-catalog-entry",
            "blocker",
            entries[i].artifact_kind,
            entries[i].artifact_id,
            "catalog contains duplicate artifact identity \{duplicate_key(entries[i])}",
            recommendation="keep exactly one catalog entry per MoonData artifact id",
          ),
        )
      }
    }
  }
}

///|
fn add_manifest_file_findings(
  findings : Array[ValidationFinding],
  root : String,
  entry : @moondata_core.CatalogEntry,
) -> Unit {
  if entry.manifest_path == "" {
    return
  }
  if entry.manifest_path.contains("://") {
    findings.push(
      validation_finding(
        "catalog-entry-nonlocal-path",
        "warning",
        entry.artifact_kind,
        entry.artifact_id,
        "catalog entry points to non-local manifest path \{entry.manifest_path}",
        recommendation="store durable MoonData manifests under the selected MoonData root",
      ),
    )
    return
  }
  if !entry.manifest_path.contains(root) {
    findings.push(
      validation_finding(
        "catalog-entry-outside-root",
        "warning",
        entry.artifact_kind,
        entry.artifact_id,
        "catalog entry manifest_path is outside the MoonData root",
        recommendation="keep cataloged manifests inside the MoonData root",
      ),
    )
  }
  if !@fsx.path_exists(entry.manifest_path) {
    findings.push(
      validation_finding(
        "catalog-entry-missing-manifest",
        "blocker",
        entry.artifact_kind,
        entry.artifact_id,
        "catalog entry manifest file does not exist",
        recommendation="rewrite or remove stale catalog entries before export",
      ),
    )
  }
}

///|
fn moondata_uri_path(root : String, uri : String) -> String? {
  match uri.strip_prefix("moondata://") {
    Some(relative) =>
      if root.has_suffix("/") {
        Some(root + relative.to_owned())
      } else {
        Some(root + "/" + relative.to_owned())
      }
    None => None
  }
}

///|
fn add_data_ref_file_finding(
  findings : Array[ValidationFinding],
  root : String,
  entry : @moondata_core.CatalogEntry,
  data_ref : @moondata_core.DataRef,
) -> Unit {
  match moondata_uri_path(root, data_ref.uri) {
    Some(path) =>
      if !@fsx.path_exists(path) {
        findings.push(
          validation_finding(
            "data-ref-missing-local-payload",
            "blocker",
            entry.artifact_kind,
            entry.artifact_id,
            "MoonData data ref \{data_ref.ref_id} points to missing payload \{data_ref.uri}",
            recommendation="restore the payload under the MoonData root or remove the stale ref",
          ),
        )
      }
    None => ()
  }
}

///|
fn add_data_refs_file_findings(
  findings : Array[ValidationFinding],
  root : String,
  entry : @moondata_core.CatalogEntry,
  refs : Array[@moondata_core.DataRef],
) -> Unit {
  for data_ref in refs {
    add_data_ref_file_finding(findings, root, entry, data_ref)
  }
}

///|
fn manifest_json(
  findings : Array[ValidationFinding],
  entry : @moondata_core.CatalogEntry,
) -> Json? {
  let text = @fsx.read_file_to_string(entry.manifest_path) catch {
    _ => return None
  }
  let json = @json.parse(text) catch {
    _ => {
      findings.push(
        validation_finding(
          "manifest-parse-failed",
          "blocker",
          entry.artifact_kind,
          entry.artifact_id,
          "catalog entry manifest cannot be parsed as JSON",
          recommendation="rewrite the manifest from MoonData contracts",
        ),
      )
      return None
    }
  }
  Some(json)
}

///|
fn add_source_payload_findings(
  findings : Array[ValidationFinding],
  root : String,
  entry : @moondata_core.CatalogEntry,
  json : Json,
) -> Unit {
  let source : @moondata_core.DataSource = @json.from_json(json) catch {
    _ => return
  }
  add_data_refs_file_findings(findings, root, entry, source.source_refs)
}

///|
fn add_capture_payload_findings(
  findings : Array[ValidationFinding],
  root : String,
  entry : @moondata_core.CatalogEntry,
  json : Json,
) -> Unit {
  let capture : @moondata_core.CaptureSession = @json.from_json(json) catch {
    _ => return
  }
  add_data_refs_file_findings(findings, root, entry, capture.data_refs)
}

///|
fn add_dataset_payload_findings(
  findings : Array[ValidationFinding],
  root : String,
  entry : @moondata_core.CatalogEntry,
  json : Json,
) -> Unit {
  let dataset : @moondata_core.DatasetManifest = @json.from_json(json) catch {
    _ => return
  }
  add_data_refs_file_findings(findings, root, entry, dataset.data_refs)
}

///|
fn add_episode_payload_findings(
  findings : Array[ValidationFinding],
  root : String,
  entry : @moondata_core.CatalogEntry,
  json : Json,
) -> Unit {
  let episode : @moondata_core.EpisodeManifest = @json.from_json(json) catch {
    _ => return
  }
  add_data_refs_file_findings(findings, root, entry, episode.data_refs)
}

///|
fn add_frame_payload_findings(
  findings : Array[ValidationFinding],
  root : String,
  entry : @moondata_core.CatalogEntry,
  json : Json,
) -> Unit {
  let frame : @moondata_core.FrameRef = @json.from_json(json) catch {
    _ => return
  }
  match frame.payload_ref {
    Some(data_ref) => add_data_ref_file_finding(findings, root, entry, data_ref)
    None => ()
  }
  add_data_refs_file_findings(findings, root, entry, frame.signal_refs)
  add_data_refs_file_findings(findings, root, entry, frame.media_refs)
}

///|
fn add_payload_file_findings(
  findings : Array[ValidationFinding],
  root : String,
  entry : @moondata_core.CatalogEntry,
) -> Unit {
  if entry.manifest_path == "" ||
    entry.manifest_path.contains("://") ||
    !@fsx.path_exists(entry.manifest_path) {
    return
  }
  let json = match manifest_json(findings, entry) {
    Some(value) => value
    None => return
  }
  match entry.artifact_kind {
    "source" => add_source_payload_findings(findings, root, entry, json)
    "capture" => add_capture_payload_findings(findings, root, entry, json)
    "dataset" => add_dataset_payload_findings(findings, root, entry, json)
    "episode" => add_episode_payload_findings(findings, root, entry, json)
    "frame" => add_frame_payload_findings(findings, root, entry, json)
    _ => ()
  }
}

///|
pub fn validate_catalog(
  root : String,
  catalog : @moondata_core.MoonDataCatalog,
  generated_at_ms? : Int64 = 0L,
  check_files? : Bool = false,
) -> ValidationReport {
  let findings : Array[ValidationFinding] = []
  if catalog.entry_count != catalog.entries.length() {
    findings.push(
      validation_finding(
        "catalog-entry-count-mismatch",
        "blocker",
        "catalog",
        catalog.catalog_id,
        "catalog entry_count \{catalog.entry_count} does not match \{catalog.entries.length()} entries",
        recommendation="regenerate the MoonData catalog from current manifests",
      ),
    )
  }
  if catalog.entries.length() == 0 {
    findings.push(
      validation_finding(
        "catalog-empty",
        "warning",
        "catalog",
        catalog.catalog_id,
        "catalog has no entries",
        recommendation="register captures or curated artifacts before publishing this data root",
      ),
    )
  }
  for entry in catalog.entries {
    add_entry_shape_findings(findings, entry)
    if check_files {
      add_manifest_file_findings(findings, root, entry)
      add_payload_file_findings(findings, root, entry)
    }
  }
  add_duplicate_findings(findings, catalog.entries)
  let blocker_count = count_severity(findings, "blocker")
  let warning_count = count_severity(findings, "warning")
  {
    root,
    generated_at_ms,
    status: if blocker_count > 0 {
      "blocked"
    } else if warning_count > 0 {
      "review"
    } else {
      "passed"
    },
    catalog_entry_count: catalog.entries.length(),
    finding_count: findings.length(),
    blocker_count,
    warning_count,
    findings,
  }
}

///|
pub fn validate_root(
  root : String,
  generated_at_ms? : Int64 = 0L,
) -> Result[ValidationReport, @moondata_store.MoonDataStoreIssue] {
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok(validate_catalog(root, catalog, generated_at_ms~, check_files=true))
}
