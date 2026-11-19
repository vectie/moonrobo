///|
pub(all) struct WindowRef {
  episode_id : String
  start_step : Int32
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Numeric values flattened in [window, step, channel] order. Context is
/// [window, context_channel]. Axes are retained in layout, with no episodes.
pub(all) struct TrainingBatch {
  format : String
  layout : MotionDataset
  split : String
  window_length : Int32
  windows : Array[WindowRef]
  time_s : Array[Double]
  state : Array[Double]
  observation : Array[Double]
  applied_action : Array[Double]
  next_state : Array[Double]
  goal : Array[Double]
  context : Array[Double]
  reward : Array[Double]
  terminated : Array[Bool]
  truncated : Array[Bool]
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Build fixed-length windows, optionally spacing starts by `stride` steps.
/// The final complete window is retained even when off the stride grid, so
/// coarse exports retain episode-end labels. Default stride one is unchanged.
/// Gaps outside relative 1e-6 cadence
/// tolerance exclude windows; neither gaps nor episode boundaries are filled.
/// A final transition may terminate or truncate; consumers choose bootstrap
/// masks from those two distinct arrays.
pub fn MotionDataset::windows(
  self : MotionDataset,
  split~ : String,
  length~ : Int32,
  stride~ : Int32 = 1,
) -> Result[TrainingBatch, String] {
  match self.validate() {
    Err(message) => return Err(message)
    Ok(_) => ()
  }
  if length <= 0 ||
    stride <= 0 ||
    !["train", "validation", "test"].contains(split) {
    return Err("positive window length/stride and explicit split required")
  }
  let result : TrainingBatch = {
    format: "moonrobo.training-batch.v1",
    layout: { ..self, episodes: [], },
    split,
    window_length: length,
    windows: [],
    time_s: [],
    state: [],
    observation: [],
    applied_action: [],
    next_state: [],
    goal: [],
    context: [],
    reward: [],
    terminated: [],
    truncated: [],
  }
  for episode in self.episodes {
    if episode.split != split || episode.steps.length() < length {
      continue
    }
    for start in 0..<=(episode.steps.length() - length) {
      if start % stride != 0 && start != episode.steps.length() - length {
        continue
      }
      let mut contiguous = true
      for offset in 1..<length {
        let delta = episode.steps[start + offset].time_s -
          episode.steps[start + offset - 1].time_s
        if (delta / self.dt_s - 1.0).abs() > 1.0e-6 {
          contiguous = false
        }
      }
      if !contiguous {
        continue
      }
      result.windows.push({ episode_id: episode.id, start_step: start, })
      result.context.append(episode.context)
      for offset in 0..<length {
        let step = episode.steps[start + offset]
        result.time_s.push(step.time_s)
        result.state.append(step.state)
        result.observation.append(step.observation)
        result.applied_action.append(step.applied_action)
        result.next_state.append(step.next_state)
        result.goal.append(step.goal)
        result.reward.push(step.reward)
        result.terminated.push(step.terminated)
        result.truncated.push(step.truncated)
      }
    }
  }
  Ok(result)
}
