///|
pub(all) struct QualityConfig {
  min_frame_count : Int
  max_frame_gap_ms : Int64
  expected_robot_id : String
  expected_bridge_id : String
  require_stopped_episode : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn default_quality_config(
  expected_robot_id? : String = "",
  expected_bridge_id? : String = "",
  min_frame_count? : Int = 1,
  max_frame_gap_ms? : Int64 = 250L,
  require_stopped_episode? : Bool = true,
) -> QualityConfig {
  {
    min_frame_count,
    max_frame_gap_ms,
    expected_robot_id,
    expected_bridge_id,
    require_stopped_episode,
  }
}

///|
fn finding(
  rule_id : String,
  severity : String,
  target_kind : String,
  target_id : String,
  message : String,
  recommendation? : String = "",
) -> @moondata_core.QualityFinding {
  @moondata_core.quality_finding(
    "\{rule_id}-\{target_id}",
    rule_id,
    severity,
    target_kind,
    target_id,
    message,
    recommendation~,
  )
}

///|
fn add_identity_findings(
  findings : Array[@moondata_core.QualityFinding],
  episode : @moondata_core.EpisodeManifest,
  config : QualityConfig,
) -> Unit {
  if config.expected_robot_id != "" &&
    episode.robot_id != config.expected_robot_id {
    findings.push(
      finding(
        "robot-id-mismatch",
        "blocker",
        "episode",
        episode.episode_id,
        "episode robot_id \{episode.robot_id} does not match expected \{config.expected_robot_id}",
        recommendation="do not mix this episode into the selected robot dataset",
      ),
    )
  }
  if config.expected_bridge_id != "" &&
    episode.bridge_id != config.expected_bridge_id {
    findings.push(
      finding(
        "bridge-id-mismatch",
        "blocker",
        "episode",
        episode.episode_id,
        "episode bridge_id \{episode.bridge_id} does not match expected \{config.expected_bridge_id}",
        recommendation="verify the capture source before curation",
      ),
    )
  }
}

///|
fn add_episode_shape_findings(
  findings : Array[@moondata_core.QualityFinding],
  episode : @moondata_core.EpisodeManifest,
  frames : Array[@moondata_core.FrameRef],
  config : QualityConfig,
) -> Unit {
  if config.require_stopped_episode && episode.status != "stopped" {
    findings.push(
      finding(
        "episode-not-stopped",
        "blocker",
        "episode",
        episode.episode_id,
        "episode status is \{episode.status}, expected stopped",
        recommendation="stop or close the capture before treating it as a dataset episode",
      ),
    )
  }
  if frames.length() < config.min_frame_count {
    findings.push(
      finding(
        "too-few-frames",
        "blocker",
        "episode",
        episode.episode_id,
        "episode has \{frames.length()} frame(s), expected at least \{config.min_frame_count}",
      ),
    )
  }
  if episode.frame_count != frames.length() {
    findings.push(
      finding(
        "frame-count-mismatch",
        "blocker",
        "episode",
        episode.episode_id,
        "episode manifest frame_count \{episode.frame_count} does not match \{frames.length()} frame refs",
      ),
    )
  }
  if episode.frame_ids.length() != frames.length() {
    findings.push(
      finding(
        "frame-id-count-mismatch",
        "warning",
        "episode",
        episode.episode_id,
        "episode frame_ids count \{episode.frame_ids.length()} does not match \{frames.length()} frame refs",
      ),
    )
  }
}

///|
fn add_frame_findings(
  findings : Array[@moondata_core.QualityFinding],
  episode : @moondata_core.EpisodeManifest,
  frames : Array[@moondata_core.FrameRef],
  config : QualityConfig,
) -> Unit {
  let mut previous_ms = 0L
  let mut have_previous = false
  for index in 0..<frames.length() {
    let frame = frames[index]
    if frame.episode_id != episode.episode_id {
      findings.push(
        finding(
          "frame-episode-mismatch",
          "blocker",
          "frame",
          frame.frame_id,
          "frame episode_id \{frame.episode_id} does not match episode \{episode.episode_id}",
        ),
      )
    }
    if frame.sequence_index != index {
      findings.push(
        finding(
          "frame-sequence-gap",
          "warning",
          "frame",
          frame.frame_id,
          "frame sequence_index \{frame.sequence_index} does not match expected \{index}",
        ),
      )
    }
    if frame.payload_ref is None {
      findings.push(
        finding(
          "missing-frame-payload",
          "warning",
          "frame",
          frame.frame_id,
          "frame has no payload_ref",
          recommendation="attach a payload ref before export",
        ),
      )
    }
    if have_previous {
      let gap = frame.captured_at_ms - previous_ms
      if gap < 0L {
        findings.push(
          finding(
            "nonmonotonic-time",
            "blocker",
            "frame",
            frame.frame_id,
            "frame timestamp moved backwards by \{0L - gap} ms",
          ),
        )
      } else if gap > config.max_frame_gap_ms {
        findings.push(
          finding(
            "timestamp-gap",
            "warning",
            "frame",
            frame.frame_id,
            "frame gap is \{gap} ms, expected no more than \{config.max_frame_gap_ms} ms",
          ),
        )
      }
    }
    previous_ms = frame.captured_at_ms
    have_previous = true
  }
}

///|
pub fn evaluate_episode(
  quality_run_id : @moondata_core.QualityRunId,
  dataset_id : @moondata_core.DatasetId,
  episode : @moondata_core.EpisodeManifest,
  frames : Array[@moondata_core.FrameRef],
  created_at_ms : Int64,
  config? : QualityConfig = default_quality_config(),
) -> @moondata_core.QualityRun {
  let findings : Array[@moondata_core.QualityFinding] = []
  add_identity_findings(findings, episode, config)
  add_episode_shape_findings(findings, episode, frames, config)
  add_frame_findings(findings, episode, frames, config)
  @moondata_core.quality_run(
    quality_run_id,
    dataset_id,
    [episode.episode_id],
    created_at_ms,
    findings,
  )
}
