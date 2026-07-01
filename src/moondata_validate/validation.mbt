///|
fn count_severity(
  findings : Array[@moondata_core.ValidationFinding],
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
pub(all) struct StoredValidationResult {
  root : String
  validation_report_id : String
  report_path : String
  catalog_path : String
  status : String
  finding_count : Int
  blocker_count : Int
  warning_count : Int
  report : @moondata_core.ValidationReport
} derive(Debug, Eq, ToJson, FromJson)

///|
fn validation_report_id(generated_at_ms : Int64) -> String {
  "validation-\{generated_at_ms}"
}

///|
fn duplicate_key(entry : @moondata_core.CatalogEntry) -> String {
  "\{entry.artifact_kind}:\{entry.artifact_id}"
}

///|
fn add_entry_shape_findings(
  findings : Array[@moondata_core.ValidationFinding],
  entry : @moondata_core.CatalogEntry,
) -> Unit {
  if entry.artifact_kind == "" {
    findings.push(
      @moondata_core.validation_finding(
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
      @moondata_core.validation_finding(
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
      @moondata_core.validation_finding(
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
  findings : Array[@moondata_core.ValidationFinding],
  entries : Array[@moondata_core.CatalogEntry],
) -> Unit {
  for i in 0..<entries.length() {
    for j in (i + 1)..<entries.length() {
      if duplicate_key(entries[i]) == duplicate_key(entries[j]) {
        findings.push(
          @moondata_core.validation_finding(
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
  findings : Array[@moondata_core.ValidationFinding],
  root : String,
  entry : @moondata_core.CatalogEntry,
) -> Unit {
  if entry.manifest_path == "" {
    return
  }
  if entry.manifest_path.contains("://") {
    findings.push(
      @moondata_core.validation_finding(
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
      @moondata_core.validation_finding(
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
      @moondata_core.validation_finding(
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
  findings : Array[@moondata_core.ValidationFinding],
  root : String,
  entry : @moondata_core.CatalogEntry,
  data_ref : @moondata_core.DataRef,
) -> Unit {
  match moondata_uri_path(root, data_ref.uri) {
    Some(path) => {
      if !@fsx.path_exists(path) {
        findings.push(
          @moondata_core.validation_finding(
            "data-ref-missing-local-payload",
            "blocker",
            entry.artifact_kind,
            entry.artifact_id,
            "MoonData data ref \{data_ref.ref_id} points to missing payload \{data_ref.uri}",
            recommendation="restore the payload under the MoonData root or remove the stale ref",
          ),
        )
        return
      }
      let text = @fsx.read_file_to_string(path) catch {
        _ => {
          findings.push(
            @moondata_core.validation_finding(
              "data-ref-unreadable-local-payload",
              "blocker",
              entry.artifact_kind,
              entry.artifact_id,
              "MoonData data ref \{data_ref.ref_id} points to unreadable payload \{data_ref.uri}",
              recommendation="restore a readable payload under the MoonData root",
            ),
          )
          return
        }
      }
      let actual_byte_count = text.length().to_int64()
      if data_ref.byte_count > 0L && data_ref.byte_count != actual_byte_count {
        findings.push(
          @moondata_core.validation_finding(
            "data-ref-byte-count-mismatch",
            "blocker",
            entry.artifact_kind,
            entry.artifact_id,
            "MoonData data ref \{data_ref.ref_id} byte_count \{data_ref.byte_count} does not match payload length \{actual_byte_count}",
            recommendation="rewrite the DataRef from the current payload or restore the original payload",
          ),
        )
      }
      let actual_checksum = @moondata_core.text_checksum(text)
      if data_ref.checksum != "" && data_ref.checksum != actual_checksum {
        findings.push(
          @moondata_core.validation_finding(
            "data-ref-checksum-mismatch",
            "blocker",
            entry.artifact_kind,
            entry.artifact_id,
            "MoonData data ref \{data_ref.ref_id} checksum \{data_ref.checksum} does not match \{actual_checksum}",
            recommendation="rewrite the DataRef from the current payload or restore the original payload",
          ),
        )
      }
    }
    None => ()
  }
}

///|
fn add_data_refs_file_findings(
  findings : Array[@moondata_core.ValidationFinding],
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
  findings : Array[@moondata_core.ValidationFinding],
  entry : @moondata_core.CatalogEntry,
) -> Json? {
  let text = @fsx.read_file_to_string(entry.manifest_path) catch {
    _ => return None
  }
  let json = @json.parse(text) catch {
    _ => {
      findings.push(
        @moondata_core.validation_finding(
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
  findings : Array[@moondata_core.ValidationFinding],
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
  findings : Array[@moondata_core.ValidationFinding],
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
  findings : Array[@moondata_core.ValidationFinding],
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
  findings : Array[@moondata_core.ValidationFinding],
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
  findings : Array[@moondata_core.ValidationFinding],
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
fn add_signal_payload_findings(
  findings : Array[@moondata_core.ValidationFinding],
  root : String,
  entry : @moondata_core.CatalogEntry,
  json : Json,
) -> Unit {
  let signal : @moondata_core.SignalSeries = @json.from_json(json) catch {
    _ => return
  }
  add_data_ref_file_finding(findings, root, entry, signal.storage_ref)
}

///|
fn add_export_payload_findings(
  findings : Array[@moondata_core.ValidationFinding],
  root : String,
  entry : @moondata_core.CatalogEntry,
  json : Json,
) -> Unit {
  let manifest : @moondata_core.ExportManifest = @json.from_json(json) catch {
    _ => return
  }
  add_data_refs_file_findings(findings, root, entry, manifest.output_refs)
}

///|
fn add_replay_payload_findings(
  findings : Array[@moondata_core.ValidationFinding],
  root : String,
  entry : @moondata_core.CatalogEntry,
  json : Json,
) -> Unit {
  let replay : @moondata_core.ReplayArtifact = @json.from_json(json) catch {
    _ => return
  }
  add_data_refs_file_findings(findings, root, entry, replay.generated_refs)
}

///|
fn add_payload_file_findings(
  findings : Array[@moondata_core.ValidationFinding],
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
    "signal-series" => add_signal_payload_findings(findings, root, entry, json)
    "replay-artifact" =>
      add_replay_payload_findings(findings, root, entry, json)
    "export-manifest" =>
      add_export_payload_findings(findings, root, entry, json)
    _ => ()
  }
}

///|
fn catalog_has(
  entries : Array[@moondata_core.CatalogEntry],
  artifact_kind : String,
  artifact_id : String,
) -> Bool {
  for entry in entries {
    if entry.artifact_kind == artifact_kind && entry.artifact_id == artifact_id {
      return true
    }
  }
  false
}

///|
fn catalog_has_any_id(
  entries : Array[@moondata_core.CatalogEntry],
  artifact_id : String,
) -> Bool {
  for entry in entries {
    if entry.artifact_id == artifact_id {
      return true
    }
  }
  false
}

///|
fn add_identity_finding(
  findings : Array[@moondata_core.ValidationFinding],
  entry : @moondata_core.CatalogEntry,
  actual_id : String,
) -> Unit {
  if actual_id != entry.artifact_id {
    findings.push(
      @moondata_core.validation_finding(
        "catalog-entry-manifest-id-mismatch",
        "blocker",
        entry.artifact_kind,
        entry.artifact_id,
        "catalog id \{entry.artifact_id} does not match manifest id \{actual_id}",
        recommendation="rebuild the catalog from MoonData-owned manifests before handoff",
      ),
    )
  }
}

///|
fn add_missing_catalog_ref(
  findings : Array[@moondata_core.ValidationFinding],
  entries : Array[@moondata_core.CatalogEntry],
  entry : @moondata_core.CatalogEntry,
  target_kind : String,
  target_id : String,
  relation : String,
) -> Unit {
  if target_id == "" || catalog_has(entries, target_kind, target_id) {
    return
  }
  findings.push(
    @moondata_core.validation_finding(
      "moondata-ref-missing-catalog-entry",
      "blocker",
      entry.artifact_kind,
      entry.artifact_id,
      "\{entry.artifact_kind} \{entry.artifact_id} references missing \{target_kind} \{target_id} via \{relation}",
      recommendation="restore the referenced MoonData manifest or remove the stale reference",
    ),
  )
}

///|
fn add_missing_any_catalog_ref(
  findings : Array[@moondata_core.ValidationFinding],
  entries : Array[@moondata_core.CatalogEntry],
  entry : @moondata_core.CatalogEntry,
  target_id : String,
  relation : String,
) -> Unit {
  if target_id == "" || catalog_has_any_id(entries, target_id) {
    return
  }
  findings.push(
    @moondata_core.validation_finding(
      "moondata-ref-missing-catalog-entry",
      "blocker",
      entry.artifact_kind,
      entry.artifact_id,
      "\{entry.artifact_kind} \{entry.artifact_id} references missing MoonData artifact \{target_id} via \{relation}",
      recommendation="restore the referenced MoonData manifest or remove the stale lineage edge",
    ),
  )
}

///|
fn add_moondata_ref_findings(
  findings : Array[@moondata_core.ValidationFinding],
  entries : Array[@moondata_core.CatalogEntry],
  entry : @moondata_core.CatalogEntry,
  refs : Array[@moondata_core.MoonDataRef],
  relation : String,
) -> Unit {
  for moondata_ref in refs {
    add_missing_catalog_ref(
      findings,
      entries,
      entry,
      moondata_ref.artifact_kind,
      moondata_ref.artifact_id,
      relation,
    )
  }
}

///|
fn add_source_reference_findings(
  findings : Array[@moondata_core.ValidationFinding],
  entry : @moondata_core.CatalogEntry,
  json : Json,
) -> Unit {
  let source : @moondata_core.DataSource = @json.from_json(json) catch {
    _ => return
  }
  add_identity_finding(findings, entry, source.source_id)
}

///|
fn add_capture_reference_findings(
  findings : Array[@moondata_core.ValidationFinding],
  entries : Array[@moondata_core.CatalogEntry],
  entry : @moondata_core.CatalogEntry,
  json : Json,
) -> Unit {
  let capture : @moondata_core.CaptureSession = @json.from_json(json) catch {
    _ => return
  }
  add_identity_finding(findings, entry, capture.capture_id)
  add_missing_catalog_ref(
    findings,
    entries,
    entry,
    "source",
    capture.source_id,
    "source_id",
  )
}

///|
fn add_dataset_reference_findings(
  findings : Array[@moondata_core.ValidationFinding],
  entries : Array[@moondata_core.CatalogEntry],
  entry : @moondata_core.CatalogEntry,
  json : Json,
) -> Unit {
  let dataset : @moondata_core.DatasetManifest = @json.from_json(json) catch {
    _ => return
  }
  add_identity_finding(findings, entry, dataset.dataset_id)
  for source_id in dataset.source_ids {
    add_missing_catalog_ref(
      findings, entries, entry, "source", source_id, "source_ids",
    )
  }
  for capture_id in dataset.capture_ids {
    add_missing_catalog_ref(
      findings, entries, entry, "capture", capture_id, "capture_ids",
    )
  }
  for episode_id in dataset.episode_ids {
    add_missing_catalog_ref(
      findings, entries, entry, "episode", episode_id, "episode_ids",
    )
  }
  if dataset.lineage_id != "" {
    add_missing_catalog_ref(
      findings,
      entries,
      entry,
      "lineage",
      dataset.lineage_id,
      "lineage_id",
    )
  }
}

///|
fn add_episode_reference_findings(
  findings : Array[@moondata_core.ValidationFinding],
  entries : Array[@moondata_core.CatalogEntry],
  entry : @moondata_core.CatalogEntry,
  json : Json,
) -> Unit {
  let episode : @moondata_core.EpisodeManifest = @json.from_json(json) catch {
    _ => return
  }
  add_identity_finding(findings, entry, episode.episode_id)
  add_missing_catalog_ref(
    findings,
    entries,
    entry,
    "dataset",
    episode.dataset_id,
    "dataset_id",
  )
  if episode.frame_count != episode.frame_ids.length() {
    findings.push(
      @moondata_core.validation_finding(
        "episode-frame-count-mismatch",
        "blocker",
        entry.artifact_kind,
        entry.artifact_id,
        "episode frame_count \{episode.frame_count} does not match \{episode.frame_ids.length()} frame id(s)",
        recommendation="rewrite the episode manifest from canonical frame refs",
      ),
    )
  }
  for frame_id in episode.frame_ids {
    add_missing_catalog_ref(
      findings, entries, entry, "frame", frame_id, "frame_ids",
    )
  }
}

///|
fn add_frame_reference_findings(
  findings : Array[@moondata_core.ValidationFinding],
  entries : Array[@moondata_core.CatalogEntry],
  entry : @moondata_core.CatalogEntry,
  json : Json,
) -> Unit {
  let frame : @moondata_core.FrameRef = @json.from_json(json) catch {
    _ => return
  }
  add_identity_finding(findings, entry, frame.frame_id)
  add_missing_catalog_ref(
    findings,
    entries,
    entry,
    "episode",
    frame.episode_id,
    "episode_id",
  )
}

///|
fn add_signal_reference_findings(
  findings : Array[@moondata_core.ValidationFinding],
  entries : Array[@moondata_core.CatalogEntry],
  entry : @moondata_core.CatalogEntry,
  json : Json,
) -> Unit {
  let signal : @moondata_core.SignalSeries = @json.from_json(json) catch {
    _ => return
  }
  add_identity_finding(findings, entry, signal.series_id)
  add_missing_catalog_ref(
    findings,
    entries,
    entry,
    "dataset",
    signal.dataset_id,
    "dataset_id",
  )
  add_missing_catalog_ref(
    findings,
    entries,
    entry,
    "episode",
    signal.episode_id,
    "episode_id",
  )
}

///|
fn add_quality_reference_findings(
  findings : Array[@moondata_core.ValidationFinding],
  entries : Array[@moondata_core.CatalogEntry],
  entry : @moondata_core.CatalogEntry,
  json : Json,
) -> Unit {
  let quality : @moondata_core.QualityRun = @json.from_json(json) catch {
    _ => return
  }
  add_identity_finding(findings, entry, quality.quality_run_id)
  add_missing_catalog_ref(
    findings,
    entries,
    entry,
    "dataset",
    quality.dataset_id,
    "dataset_id",
  )
  if quality.finding_count != quality.findings.length() {
    findings.push(
      @moondata_core.validation_finding(
        "quality-finding-count-mismatch",
        "blocker",
        entry.artifact_kind,
        entry.artifact_id,
        "quality finding_count \{quality.finding_count} does not match \{quality.findings.length()} finding(s)",
        recommendation="rewrite the quality run from evaluated findings",
      ),
    )
  }
  for episode_id in quality.episode_ids {
    add_missing_catalog_ref(
      findings, entries, entry, "episode", episode_id, "episode_ids",
    )
  }
  for finding in quality.findings {
    add_moondata_ref_findings(
      findings,
      entries,
      entry,
      finding.evidence_refs,
      "finding.evidence_refs",
    )
  }
}

///|
fn add_transform_reference_findings(
  findings : Array[@moondata_core.ValidationFinding],
  entries : Array[@moondata_core.CatalogEntry],
  entry : @moondata_core.CatalogEntry,
  json : Json,
) -> Unit {
  let transform : @moondata_core.TransformRun = @json.from_json(json) catch {
    _ => return
  }
  add_identity_finding(findings, entry, transform.transform_run_id)
  add_missing_catalog_ref(
    findings,
    entries,
    entry,
    "dataset",
    transform.input_dataset_id,
    "input_dataset_id",
  )
  add_missing_catalog_ref(
    findings,
    entries,
    entry,
    "dataset",
    transform.output_dataset_id,
    "output_dataset_id",
  )
  if transform.step_count != transform.steps.length() {
    findings.push(
      @moondata_core.validation_finding(
        "transform-step-count-mismatch",
        "blocker",
        entry.artifact_kind,
        entry.artifact_id,
        "transform step_count \{transform.step_count} does not match \{transform.steps.length()} step(s)",
        recommendation="rewrite the transform run from its executed transform graph",
      ),
    )
  }
  for quality_run_id in transform.quality_run_ids {
    add_missing_catalog_ref(
      findings, entries, entry, "quality-run", quality_run_id, "quality_run_ids",
    )
  }
  if transform.lineage_id != "" {
    add_missing_catalog_ref(
      findings,
      entries,
      entry,
      "lineage",
      transform.lineage_id,
      "lineage_id",
    )
  }
  add_moondata_ref_findings(
    findings,
    entries,
    entry,
    transform.rejected_refs,
    "rejected_refs",
  )
}

///|
fn add_version_reference_findings(
  findings : Array[@moondata_core.ValidationFinding],
  entries : Array[@moondata_core.CatalogEntry],
  entry : @moondata_core.CatalogEntry,
  json : Json,
) -> Unit {
  let version : @moondata_core.DatasetVersion = @json.from_json(json) catch {
    _ => return
  }
  add_identity_finding(findings, entry, version.version_id)
  add_missing_catalog_ref(
    findings,
    entries,
    entry,
    "dataset",
    version.dataset_id,
    "dataset_id",
  )
  for parent_version_id in version.parent_version_ids {
    add_missing_catalog_ref(
      findings, entries, entry, "dataset-version", parent_version_id, "parent_version_ids",
    )
  }
  for episode_id in version.accepted_episode_ids {
    add_missing_catalog_ref(
      findings, entries, entry, "episode", episode_id, "accepted_episode_ids",
    )
  }
  for quality_run_id in version.quality_run_ids {
    add_missing_catalog_ref(
      findings, entries, entry, "quality-run", quality_run_id, "quality_run_ids",
    )
  }
}

///|
fn add_annotation_reference_findings(
  findings : Array[@moondata_core.ValidationFinding],
  entries : Array[@moondata_core.CatalogEntry],
  entry : @moondata_core.CatalogEntry,
  json : Json,
) -> Unit {
  let set : @moondata_core.AnnotationSet = @json.from_json(json) catch {
    _ => return
  }
  add_identity_finding(findings, entry, set.annotation_set_id)
  add_moondata_ref_findings(
    findings,
    entries,
    entry,
    set.target_refs,
    "target_refs",
  )
  add_moondata_ref_findings(
    findings,
    entries,
    entry,
    set.evidence_refs,
    "evidence_refs",
  )
}

///|
fn add_replay_reference_findings(
  findings : Array[@moondata_core.ValidationFinding],
  entries : Array[@moondata_core.CatalogEntry],
  entry : @moondata_core.CatalogEntry,
  json : Json,
) -> Unit {
  let replay : @moondata_core.ReplayArtifact = @json.from_json(json) catch {
    _ => return
  }
  add_identity_finding(findings, entry, replay.replay_artifact_id)
  add_missing_catalog_ref(
    findings,
    entries,
    entry,
    "dataset",
    replay.dataset_id,
    "dataset_id",
  )
  for episode_id in replay.episode_ids {
    add_missing_catalog_ref(
      findings, entries, entry, "episode", episode_id, "episode_ids",
    )
  }
  add_moondata_ref_findings(
    findings,
    entries,
    entry,
    replay.source_refs,
    "source_refs",
  )
}

///|
fn add_export_reference_findings(
  findings : Array[@moondata_core.ValidationFinding],
  entries : Array[@moondata_core.CatalogEntry],
  entry : @moondata_core.CatalogEntry,
  json : Json,
) -> Unit {
  let manifest : @moondata_core.ExportManifest = @json.from_json(json) catch {
    _ => return
  }
  add_identity_finding(findings, entry, manifest.export_manifest_id)
  add_missing_catalog_ref(
    findings,
    entries,
    entry,
    "dataset-version",
    manifest.input_version_id,
    "input_version_id",
  )
  add_missing_catalog_ref(
    findings,
    entries,
    entry,
    "dataset",
    manifest.dataset_id,
    "dataset_id",
  )
  for quality_run_id in manifest.quality_run_ids {
    add_missing_catalog_ref(
      findings, entries, entry, "quality-run", quality_run_id, "quality_run_ids",
    )
  }
}

///|
fn add_validation_report_reference_findings(
  findings : Array[@moondata_core.ValidationFinding],
  entry : @moondata_core.CatalogEntry,
  json : Json,
) -> Unit {
  let report : @moondata_core.ValidationReport = @json.from_json(json) catch {
    _ => return
  }
  add_identity_finding(findings, entry, report.validation_report_id)
}

///|
fn add_lineage_reference_findings(
  findings : Array[@moondata_core.ValidationFinding],
  entries : Array[@moondata_core.CatalogEntry],
  entry : @moondata_core.CatalogEntry,
  json : Json,
) -> Unit {
  let lineage : @moondata_core.LineageManifest = @json.from_json(json) catch {
    _ => return
  }
  add_identity_finding(findings, entry, lineage.lineage_id)
  add_missing_catalog_ref(
    findings,
    entries,
    entry,
    "dataset",
    lineage.root_dataset_id,
    "root_dataset_id",
  )
  for edge in lineage.edges {
    add_missing_any_catalog_ref(
      findings,
      entries,
      entry,
      edge.from_id,
      "edge.from_id",
    )
    add_missing_any_catalog_ref(
      findings,
      entries,
      entry,
      edge.to_id,
      "edge.to_id",
    )
  }
}

///|
fn add_manifest_reference_findings(
  findings : Array[@moondata_core.ValidationFinding],
  entries : Array[@moondata_core.CatalogEntry],
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
    "source" => add_source_reference_findings(findings, entry, json)
    "capture" => add_capture_reference_findings(findings, entries, entry, json)
    "dataset" => add_dataset_reference_findings(findings, entries, entry, json)
    "episode" => add_episode_reference_findings(findings, entries, entry, json)
    "frame" => add_frame_reference_findings(findings, entries, entry, json)
    "signal-series" =>
      add_signal_reference_findings(findings, entries, entry, json)
    "quality-run" =>
      add_quality_reference_findings(findings, entries, entry, json)
    "transform-run" =>
      add_transform_reference_findings(findings, entries, entry, json)
    "dataset-version" =>
      add_version_reference_findings(findings, entries, entry, json)
    "annotation-set" =>
      add_annotation_reference_findings(findings, entries, entry, json)
    "replay-artifact" =>
      add_replay_reference_findings(findings, entries, entry, json)
    "export-manifest" =>
      add_export_reference_findings(findings, entries, entry, json)
    "lineage" => add_lineage_reference_findings(findings, entries, entry, json)
    "validation-report" =>
      add_validation_report_reference_findings(findings, entry, json)
    _ => ()
  }
}

///|
pub fn validate_catalog(
  root : String,
  catalog : @moondata_core.MoonDataCatalog,
  generated_at_ms? : Int64 = 0L,
  check_files? : Bool = false,
) -> @moondata_core.ValidationReport {
  let findings : Array[@moondata_core.ValidationFinding] = []
  if catalog.entry_count != catalog.entries.length() {
    findings.push(
      @moondata_core.validation_finding(
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
      @moondata_core.validation_finding(
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
      add_manifest_reference_findings(findings, catalog.entries, entry)
    }
  }
  add_duplicate_findings(findings, catalog.entries)
  let blocker_count = count_severity(findings, "blocker")
  let warning_count = count_severity(findings, "warning")
  @moondata_core.validation_report(
    validation_report_id(generated_at_ms),
    root,
    generated_at_ms,
    if blocker_count > 0 {
      "blocked"
    } else if warning_count > 0 {
      "review"
    } else {
      "passed"
    },
    catalog.entries.length(),
    findings.length(),
    blocker_count,
    warning_count,
    findings,
  )
}

///|
pub fn validate_root(
  root : String,
  generated_at_ms? : Int64 = 0L,
) -> Result[@moondata_core.ValidationReport, @moondata_store.MoonDataStoreIssue] {
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok(validate_catalog(root, catalog, generated_at_ms~, check_files=true))
}

///|
fn append_validation_entry(
  entries : Array[@moondata_core.CatalogEntry],
  report : @moondata_core.ValidationReport,
  persisted : @moondata_store.PersistedManifest,
) -> Array[@moondata_core.CatalogEntry] {
  let next : Array[@moondata_core.CatalogEntry] = []
  for entry in entries {
    if !(entry.artifact_kind == persisted.artifact_kind &&
      entry.artifact_id == persisted.artifact_id) {
      next.push(entry)
    }
  }
  next.push(
    @moondata_core.catalog_entry(
      persisted.artifact_kind,
      persisted.artifact_id,
      persisted.path,
      status=report.status,
      summary="\{report.finding_count} validation finding(s)",
    ),
  )
  next
}

///|
pub fn validate_and_write_root(
  root : String,
  generated_at_ms? : Int64 = 0L,
) -> Result[StoredValidationResult, @moondata_store.MoonDataStoreIssue] {
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let report = validate_catalog(
    root,
    catalog,
    generated_at_ms~,
    check_files=true,
  )
  let persisted = match @moondata_store.write_validation_report(root, report) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let updated_catalog = @moondata_core.moondata_catalog(
    root,
    generated_at_ms,
    append_validation_entry(catalog.entries, report, persisted),
  )
  let catalog_persisted = match
    @moondata_store.write_catalog(root, updated_catalog) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    root,
    validation_report_id: report.validation_report_id,
    report_path: persisted.path,
    catalog_path: catalog_persisted.path,
    status: report.status,
    finding_count: report.finding_count,
    blocker_count: report.blocker_count,
    warning_count: report.warning_count,
    report,
  })
}
