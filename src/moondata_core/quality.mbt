///|
pub(all) struct QualityFinding {
  finding_id : FindingId
  rule_id : String
  severity : String
  target_kind : String
  target_id : String
  message : String
  evidence_refs : Array[MoonDataRef]
  recommendation : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn quality_finding(
  finding_id : FindingId,
  rule_id : String,
  severity : String,
  target_kind : String,
  target_id : String,
  message : String,
  recommendation? : String = "",
  evidence_refs? : Array[MoonDataRef] = [],
) -> QualityFinding {
  {
    finding_id,
    rule_id,
    severity,
    target_kind,
    target_id,
    message,
    evidence_refs,
    recommendation,
  }
}

///|
pub(all) struct QualityRun {
  quality_run_id : QualityRunId
  dataset_id : DatasetId
  episode_ids : Array[EpisodeId]
  created_at_ms : Int64
  status : String
  finding_count : Int
  blocker_count : Int
  warning_count : Int
  findings : Array[QualityFinding]
} derive(Debug, Eq, ToJson, FromJson)

///|
fn count_severity(findings : Array[QualityFinding], severity : String) -> Int {
  let mut count = 0
  for finding in findings {
    if finding.severity == severity {
      count += 1
    }
  }
  count
}

///|
pub fn quality_run(
  quality_run_id : QualityRunId,
  dataset_id : DatasetId,
  episode_ids : Array[EpisodeId],
  created_at_ms : Int64,
  findings : Array[QualityFinding],
) -> QualityRun {
  let blocker_count = count_severity(findings, "blocker")
  let warning_count = count_severity(findings, "warning")
  {
    quality_run_id,
    dataset_id,
    episode_ids,
    created_at_ms,
    status: if blocker_count > 0 {
      "blocked"
    } else if warning_count > 0 {
      "review"
    } else {
      "passed"
    },
    finding_count: findings.length(),
    blocker_count,
    warning_count,
    findings,
  }
}
