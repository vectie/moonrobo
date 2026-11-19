///|
fn read_payload_json(root : String, data_ref : @data.DataRef) -> Json raise {
  let relative = @data.moondata_payload_uri_relative_path(data_ref.uri).unwrap_or_else(() => {
      fail("unsafe physics ref")
    },
  )
  let path = root + "/" + relative
  guard need(@blob.local_file_checksum(path)) == data_ref.checksum else {
    fail("physics evidence checksum mismatch")
  }
  @json.parse(@fsx.read_file_to_string(path))
}

///|
fn read_registered_physics(
  root : String,
  id : String,
  seed : Int32,
  mode : String,
) -> LearningPhysics raise {
  let experiment = read_experiment(root, id)
  guard experiment.candidates.any(candidate => candidate.seed == seed) else {
    fail("no registered candidate for this seed")
  }
  guard [
    "original", "repeat-two-second", "fresh-two-second", "fresh-ten-second",
  ].contains(mode) else {
    fail("unknown recorded evaluation mode")
  }
  let relative = if mode == "original" {
    "policy/physics-seed-\{seed}.json"
  } else {
    "candidate-followup/seed-\{seed}-" + mode + "/physics.json"
  }
  let kind = if mode == "original" {
    "learning-physics-trace"
  } else {
    "learning-followup-physics"
  }
  let mut followup : Json? = None
  let mut original_duration_s : Double? = None
  for payload in experiment.payloads {
    if payload.data_ref.kind == "learning-policy-report" {
      let value = read_payload_json(root, payload.data_ref)
      if value
        is { "experiment": { "duration_s": Number(duration, ..), .. }, .. } {
        guard finite(duration) && duration > 0.0 else {
          fail("invalid original evaluation duration")
        }
        original_duration_s = Some(duration)
      }
    }
    if payload.data_ref.kind == "learning-qualification-followup" {
      let value = read_payload_json(root, payload.data_ref)
      guard value
        is {
          "format": String("moonrobo.g1-candidate-followup.v1"),
          "physical_execution_allowed": False,
          ..
        } else {
        fail("invalid followup evidence format")
      }
      followup = Some(value)
    }
  }
  for payload in experiment.payloads {
    if payload.relative_path == relative && payload.data_ref.kind == kind {
      return {
        format: "moonrobo.learning-physics.v1",
        experiment_id: id,
        seed,
        data_ref: payload.data_ref,
        report: read_payload_json(root, payload.data_ref),
        evaluation_mode: Some(mode),
        original_duration_s,
        followup,
        physical_execution_allowed: false,
      }
    }
  }
  fail("no registered physics evidence for this evaluation")
}

///|
/// Read a registered candidate's physics evidence after checking its checksum.
///
/// ```mbt nocheck
/// let physics = @moondata_learning.read_physics("book/moondata", "round-one", 0).unwrap()
/// assert_false(physics.physical_execution_allowed)
/// ```
pub fn read_physics(
  root : String,
  id : String,
  seed : Int32,
  mode~ : String = "original",
) -> Result[LearningPhysics, String] {
  try read_registered_physics(root, id, seed, mode) catch {
    error => Err(error.to_string())
  } noraise {
    value => Ok(value)
  }
}
