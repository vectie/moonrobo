///|
pub(all) struct ProtocolSnapshotV2 {
  format : String
  config : ProtocolConfig
  num_envs : Int32
  xi : @checkpoint_stream.BlobDescriptor
  sampler : @aligned.SamplerCheckpointV2
  rng : UInt32
  exact_resume : Bool
  replay_refill_required : Bool
} derive(ToJson, FromJson)

///|
pub fn ProtocolSnapshotV2::blobs(
  self : ProtocolSnapshotV2,
) -> Array[@checkpoint_stream.BlobDescriptor] {
  let result = [self.xi]
  result.append(self.sampler.blobs())
  result
}

///|
pub async fn TrackingProtocol::write_snapshot_v2(
  self : TrackingProtocol,
  directory : String,
) -> ProtocolSnapshotV2 {
  guard !self.eval_mode else {
    fail("cannot checkpoint an evaluation protocol as training")
  }
  let xi = @checkpoint_stream.write_f64le(
    directory,
    "environment.xi.f64le",
    [self.adapter.num_envs, 33],
    (offset, count) => {
      Array::makei(count, i => {
        let flat = offset.to_int() + i
        self.xi[flat / 33][flat % 33]
      })
    },
  )
  let sampler = self.sampler.write_checkpoint_v2(directory)
  {
    format: "moonrobo.aligned.isaac-warm-stream.v2",
    config: self.config,
    num_envs: self.adapter.num_envs,
    xi,
    sampler,
    rng: self.rng.state(),
    exact_resume: false,
    replay_refill_required: true,
  }
}

///|
/// This preserves the existing warm reset protocol; no captured solver/contact
/// state is invented. Decode and validate all arrays before touching live state.
pub async fn TrackingProtocol::restore_v2(
  self : TrackingProtocol,
  directory : String,
  saved : ProtocolSnapshotV2,
) -> Bool {
  self.pending_inspection = None
  let n = self.adapter.num_envs
  guard !self.eval_mode &&
    saved.format == "moonrobo.aligned.isaac-warm-stream.v2" &&
    saved.config.to_json() == self.config.to_json() &&
    saved.num_envs == n &&
    saved.rng != 0U &&
    !saved.exact_resume &&
    saved.replay_refill_required else {
    fail("GPU warm stream checkpoint configuration differs")
  }
  @aligned.checkpoint_blob(saved.xi, "environment.xi.f64le", "f64le", [n, 33])
  for blob in saved.blobs() {
    @checkpoint_stream.verify_blob(directory, blob)
  }
  let xi = @aligned.checkpoint_read_f64(directory, saved.xi, n * 33)
  for i in 0..<n {
    guard xi[i * 33] > 0.0 else { fail("invalid GPU warm friction") }
  }
  let sampler = self.sampler.prepare_checkpoint_v2(directory, saved.sampler)
  // All metadata, sidecars and finite values are valid before these mutations.
  self.sampler.commit_checkpoint_v2(sampler)
  self.rng.set_state(saved.rng)
  for i in 0..<n {
    self.xi[i] = xi[i * 33:(i + 1) * 33].to_owned()
  }
  (self.adapter.apply_context)(self.all_ids(), self.xi, 0.3)
  self.reset()
  false
}
