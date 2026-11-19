///|
pub fn ReferenceActor::snapshot(self : ReferenceActor) -> ReferenceActor raise {
  @json.from_json(self.to_json())
}

///|
pub fn fork_actor_optimizer(
  actor : ReferenceActor,
  optimizer : @numeric.Adam,
  generator : @numeric.Rng,
) -> (ReferenceActor, @numeric.Adam, @numeric.Rng) raise {
  let branch = actor.snapshot()
  let branch_optimizer = optimizer.snapshot()
  let branch_generator = @numeric.Rng::new(1U)
  branch_generator.set_state(generator.state())
  guard branch.to_json() == actor.to_json() &&
    branch_optimizer.to_json() == optimizer.to_json() &&
    branch_generator.state() == generator.state() else {
    fail("actor/optimizer/sampler fork differs")
  }
  (branch, branch_optimizer, branch_generator)
}

///|
pub async fn save_reference_value(
  path : String,
  value : ReferenceValue,
  provenance : Json,
) -> String {
  let checkpoint = @artifacts.Checkpoint::new(
    "moonrobo.g1-reference-value.moonbit.v1",
    { "value": value.to_json(), "provenance": provenance },
  )
  let parameters = value.parameters()
  checkpoint.put("parameters", [parameters.length()], parameters)
  @artifacts.save_checkpoint(path, checkpoint)
}

///|
pub async fn load_reference_value(
  path : String,
  expected_sha256? : String,
  clips~ : Int32 = 9,
) -> ReferenceValue {
  let raw = @fs.read_file(path).binary()
  if expected_sha256 is Some(expected) {
    guard @artifacts.sha256(raw) == expected else {
      fail("value checkpoint checksum differs")
    }
  }
  if raw.length() >= 2 && raw[:2] == b"PK" {
    return reference_value_from_torch(
      @artifacts.decode_torch_checkpoint(raw),
      clips,
    )
  }
  let checkpoint = @artifacts.load_checkpoint(
    path,
    "moonrobo.g1-reference-value.moonbit.v1",
    expected_sha256?,
  )
  let value : ReferenceValue = @json.from_json(
    json_field(checkpoint.metadata, "value"),
  )
  guard value.parameters() == checkpoint.tensor("parameters").values else {
    fail("value checkpoint tensors disagree")
  }
  value
}

///|
pub fn state_digest(actor : ReferenceActor) -> String {
  @artifacts.sha256(@utf8.encode(actor.to_json().stringify()))
}

///|
pub fn optimizer_digest(optimizer : @numeric.Adam) -> String {
  @artifacts.sha256(@utf8.encode(optimizer.to_json().stringify()))
}

///|
pub fn generator_digest(generator : @numeric.Rng) -> String {
  @artifacts.sha256(@utf8.encode(generator.state().to_string()))
}

///|
/// Native portable training state. The serialized model is its own validated
/// checkpoint; replay and all optimizer moments are retained for exact native
/// continuation. This is not a Torch state_dict interchange format.
pub(all) struct ReferenceTrainingState {
  actor : ReferenceActor
  value : ReferenceValue
  model : @artifacts.Checkpoint
  replay : ReferenceModelReplay
  actor_optimizer : @numeric.Adam
  value_optimizer : @numeric.Adam
  model_optimizer : @numeric.Adam
  rng_state : UInt32
  cycle : Int32
  config : Json
  provenance : Json
} derive(ToJson, FromJson)

///|
pub async fn save_training_state(
  path : String,
  state : ReferenceTrainingState,
) -> String {
  state.model.validate()
  let checkpoint = @artifacts.Checkpoint::new(
    "moonrobo.g1-reference-training-state.moonbit.v1",
    state.to_json(),
  )
  let parameters = state.actor.parameters()
  checkpoint.put("actor.parameters", [parameters.length()], parameters)
  @artifacts.save_checkpoint(path, checkpoint)
}

///|
pub async fn load_training_state(
  path : String,
  expected_sha256? : String,
) -> ReferenceTrainingState {
  let checkpoint = @artifacts.load_checkpoint(
    path,
    "moonrobo.g1-reference-training-state.moonbit.v1",
    expected_sha256?,
  )
  let state : ReferenceTrainingState = @json.from_json(checkpoint.metadata)
  state.model.validate()
  guard state.actor.parameters() == checkpoint.tensor("actor.parameters").values else {
    fail("training-state actor tensors disagree")
  }
  guard state.cycle >= 0 && state.rng_state != 0U else {
    fail("invalid training-state cycle or RNG")
  }
  state
}
