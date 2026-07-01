///|
pub(all) struct MoonDataHandoffDossierQuery {
  version_id : String
  readiness_status : String
  validation_report_id : String
  artifact_kind : String
  artifact_id : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonDataHandoffDossierList {
  root : String
  query : MoonDataHandoffDossierQuery
  handoff_count : Int
  ready_count : Int
  ref_count : Int
  output_ref_count : Int
  total_output_byte_count : Int64
  output_checksums : Array[String]
  output_refs : Array[@moondata_core.DataRef]
  latest_handoff_dossier_id : String
  latest_handoff_generated_at_ms : Int64
  handoffs : Array[@moondata_core.HandoffDossier]
  refs : Array[@moondata_core.MoonDataRef]
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn handoff_dossier_query(
  version_id? : String = "",
  readiness_status? : String = "",
  validation_report_id? : String = "",
  artifact_kind? : String = "",
  artifact_id? : String = "",
) -> MoonDataHandoffDossierQuery {
  {
    version_id,
    readiness_status,
    validation_report_id,
    artifact_kind,
    artifact_id,
  }
}

///|
fn handoff_dossier_query_has_filters(
  query : MoonDataHandoffDossierQuery,
) -> Bool {
  query.version_id != "" ||
  query.readiness_status != "" ||
  query.validation_report_id != "" ||
  query.artifact_kind != "" ||
  query.artifact_id != ""
}

///|
fn dossier_refs_match_query(
  refs : Array[@moondata_core.MoonDataRef],
  query : MoonDataHandoffDossierQuery,
) -> Bool {
  if query.artifact_kind == "" && query.artifact_id == "" {
    return true
  }
  for dossier_ref in refs {
    let kind_matches = query.artifact_kind == "" ||
      dossier_ref.artifact_kind == query.artifact_kind
    let id_matches = query.artifact_id == "" ||
      dossier_ref.artifact_id == query.artifact_id
    if kind_matches && id_matches {
      return true
    }
  }
  false
}

///|
fn handoff_dossier_matches(
  dossier : @moondata_core.HandoffDossier,
  query : MoonDataHandoffDossierQuery,
) -> Bool {
  if query.version_id != "" && dossier.version_id != query.version_id {
    return false
  }
  if query.readiness_status != "" &&
    dossier.source_readiness_status != query.readiness_status {
    return false
  }
  if query.validation_report_id != "" &&
    dossier.source_validation_report_id != query.validation_report_id {
    return false
  }
  dossier_refs_match_query(dossier.refs, query)
}

///|
fn handoff_dossier_refs(
  root : String,
  handoffs : Array[@moondata_core.HandoffDossier],
) -> Array[@moondata_core.MoonDataRef] {
  let refs : Array[@moondata_core.MoonDataRef] = []
  for dossier in handoffs {
    refs.push(
      @moondata_core.moondata_ref(
        "handoff-dossier",
        dossier.handoff_dossier_id,
        @moondata_store.handoff_dossier_path(root, dossier.handoff_dossier_id),
        dossier.summary,
      ),
    )
  }
  refs
}

///|
priv struct HandoffDossierListSummary {
  ready_count : Int
  ref_count : Int
  output_ref_count : Int
  total_output_byte_count : Int64
  output_checksums : Array[String]
  output_refs : Array[@moondata_core.DataRef]
  latest_handoff_dossier_id : String
  latest_handoff_generated_at_ms : Int64
}

///|
fn handoff_dossier_list_summary(
  handoffs : Array[@moondata_core.HandoffDossier],
) -> HandoffDossierListSummary {
  let mut ready_count = 0
  let mut ref_count = 0
  let mut output_ref_count = 0
  let mut total_output_byte_count = 0L
  let checksums : Array[String] = []
  let output_refs : Array[@moondata_core.DataRef] = []
  let mut latest_id = ""
  let mut latest_generated_at_ms = -1L
  for dossier in handoffs {
    if dossier.source_ready {
      ready_count += 1
    }
    ref_count += dossier.ref_count
    for output in dossier.output_refs {
      output_refs.push(output)
      output_ref_count += 1
      total_output_byte_count += output.byte_count
      push_unique_checksum(checksums, output.checksum)
    }
    if dossier.generated_at_ms > latest_generated_at_ms {
      latest_id = dossier.handoff_dossier_id
      latest_generated_at_ms = dossier.generated_at_ms
    }
  }
  if latest_id == "" {
    return {
      ready_count,
      ref_count,
      output_ref_count,
      total_output_byte_count,
      output_checksums: checksums,
      output_refs,
      latest_handoff_dossier_id: "",
      latest_handoff_generated_at_ms: 0L,
    }
  }
  {
    ready_count,
    ref_count,
    output_ref_count,
    total_output_byte_count,
    output_checksums: checksums,
    output_refs,
    latest_handoff_dossier_id: latest_id,
    latest_handoff_generated_at_ms: latest_generated_at_ms,
  }
}

///|
pub fn list_handoff_dossiers(
  root : String,
  query? : MoonDataHandoffDossierQuery = handoff_dossier_query(),
) -> Result[MoonDataHandoffDossierList, @moondata_store.MoonDataStoreIssue] {
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let handoffs : Array[@moondata_core.HandoffDossier] = []
  for entry in catalog.entries {
    if entry.artifact_kind == "handoff-dossier" {
      let dossier = match
        @moondata_store.read_handoff_dossier(root, entry.artifact_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let matches = if handoff_dossier_query_has_filters(query) {
        handoff_dossier_matches(dossier, query)
      } else {
        true
      }
      if matches {
        handoffs.push(dossier)
      }
    }
  }
  let refs = handoff_dossier_refs(root, handoffs)
  let evidence = handoff_dossier_list_summary(handoffs)
  Ok({
    root,
    query,
    handoff_count: handoffs.length(),
    ready_count: evidence.ready_count,
    ref_count: evidence.ref_count,
    output_ref_count: evidence.output_ref_count,
    total_output_byte_count: evidence.total_output_byte_count,
    output_checksums: evidence.output_checksums,
    output_refs: evidence.output_refs,
    latest_handoff_dossier_id: evidence.latest_handoff_dossier_id,
    latest_handoff_generated_at_ms: evidence.latest_handoff_generated_at_ms,
    handoffs,
    refs,
    summary: "MoonData handoff dossiers: \{handoffs.length()} match(es), \{evidence.ready_count} ready, \{evidence.ref_count} ref(s), \{evidence.output_ref_count} output ref(s), \{evidence.total_output_byte_count} byte(s), latest \{evidence.latest_handoff_dossier_id}",
  })
}
