///|
/// Ordered scalar channels. Units and frame conventions are declarations;
/// this reader does not convert units or retarget between robot bodies.
pub(all) struct Axis {
  name : String
  unit : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct Transition {
  time_s : Double
  state : Array[Double]
  observation : Array[Double]
  applied_action : Array[Double]
  next_state : Array[Double]
  goal : Array[Double]
  reward : Double
  terminated : Bool
  truncated : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct Episode {
  id : String
  source_family : String
  split : String
  context : Array[Double]
  steps : Array[Transition]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MotionDataset {
  format : String
  dataset_id : String
  model_ref : String
  provenance : String
  frame_convention : String
  dt_s : Double
  state_axes : Array[Axis]
  observation_axes : Array[Axis]
  action_axes : Array[Axis]
  goal_axes : Array[Axis]
  context_axes : Array[Axis]
  episodes : Array[Episode]
} derive(Debug, Eq, ToJson, FromJson)

///|
fn finite(value : Double) -> Bool {
  value == value && value - value == 0.0
}

///|
fn axes_valid(axes : Array[Axis], allow_empty : Bool) -> Bool {
  if !allow_empty && axes.is_empty() {
    return false
  }
  let names : Array[String] = []
  for axis in axes {
    if axis.name.trim().is_empty() ||
      axis.unit.trim().is_empty() ||
      names.contains(axis.name) {
      return false
    }
    names.push(axis.name)
  }
  true
}

///|
fn vector_valid(values : Array[Double], dimension : Int32) -> Bool {
  values.length() == dimension && values.iter().all(finite)
}

///|
/// Validate learning semantics before selecting a split. Source families must
/// stay within one split, including families in unselected episodes.
pub fn MotionDataset::validate(self : MotionDataset) -> Result[Unit, String] {
  if self.format != "moonrobo.motion-dataset.v1" {
    return Err("unsupported motion dataset format")
  }
  if self.dataset_id.trim().is_empty() ||
    self.model_ref.trim().is_empty() ||
    self.provenance.trim().is_empty() ||
    self.frame_convention.trim().is_empty() {
    return Err(
      "dataset identity, model, provenance and frame convention are required",
    )
  }
  if !finite(self.dt_s) || self.dt_s <= 0.0 {
    return Err("dt_s must be finite and positive")
  }
  for
    (axes, optional) in [
      (self.state_axes, false),
      (self.observation_axes, false),
      (self.action_axes, false),
      (self.goal_axes, true),
      (self.context_axes, true),
    ] {
    if !axes_valid(axes, optional) {
      return Err("axis names must be unique and nonblank with declared units")
    }
  }
  let ids : Array[String] = []
  let families : Map[String, String] = {}
  for episode in self.episodes {
    if episode.id.trim().is_empty() ||
      ids.contains(episode.id) ||
      episode.source_family.trim().is_empty() {
      return Err(
        "episode ids must be unique and source_family must be declared",
      )
    }
    ids.push(episode.id)
    if !["train", "validation", "test"].contains(episode.split) {
      return Err("split must be train, validation or test")
    }
    if families.get(episode.source_family) is Some(split) &&
      split != episode.split {
      return Err("source family leaks across splits: " + episode.source_family)
    }
    families[episode.source_family] = episode.split
    if !vector_valid(episode.context, self.context_axes.length()) {
      return Err("context dimension or finite-value mismatch: " + episode.id)
    }
    for i, step in episode.steps {
      if !finite(step.time_s) || step.time_s < 0.0 || !finite(step.reward) {
        return Err("invalid time or reward: " + episode.id)
      }
      if i > 0 && step.time_s <= episode.steps[i - 1].time_s {
        return Err("timestamps must increase: " + episode.id)
      }
      if !vector_valid(step.state, self.state_axes.length()) ||
        !vector_valid(step.next_state, self.state_axes.length()) ||
        !vector_valid(step.observation, self.observation_axes.length()) ||
        !vector_valid(step.applied_action, self.action_axes.length()) ||
        !vector_valid(step.goal, self.goal_axes.length()) {
        return Err(
          "transition dimension or finite-value mismatch: " + episode.id,
        )
      }
      if i + 1 < episode.steps.length() && (step.terminated || step.truncated) {
        return Err("a reset must start a new episode: " + episode.id)
      }
    }
  }
  Ok(())
}

///|
/// Read concrete numeric transitions, not frame/payload references alone.
pub fn parse(text : String) -> Result[MotionDataset, String] {
  let dataset : MotionDataset = @json.from_json(@json.parse(text)) catch {
    _ => return Err("invalid motion dataset JSON")
  }
  match dataset.validate() {
    Ok(_) => Ok(dataset)
    Err(message) => Err(message)
  }
}
