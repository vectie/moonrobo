///|
pub(all) struct EnvironmentSnapshotV2 {
  format : String
  config : EnvironmentConfig
  num_envs : Int32
  integration_width : Int32
  physics : @checkpoint_stream.BlobDescriptor
  values : @checkpoint_stream.BlobDescriptor
  indices : @checkpoint_stream.BlobDescriptor
  initialized : @checkpoint_stream.BlobDescriptor
  sampler : @aligned.SamplerCheckpointV2
  rng : UInt32
} derive(ToJson, FromJson)

///|
pub fn EnvironmentSnapshotV2::blobs(
  self : EnvironmentSnapshotV2,
) -> Array[@checkpoint_stream.BlobDescriptor] {
  let result = [self.physics, self.values, self.indices, self.initialized]
  result.append(self.sampler.blobs())
  result
}

///|
fn valid_checkpoint_episode_step(
  step : Int32,
  config : EnvironmentConfig,
) -> Bool {
  // The next physical step increments before checking timeout/reset. An
  // unincrementable counter must be rejected before advancing native physics.
  step >= 0 &&
  step < 2147483647 &&
  (!config.auto_reset || config.eval_mode || step < config.max_episode_steps)
}

///|
pub async fn Environment::write_snapshot_v2(
  self : Environment,
  directory : String,
) -> EnvironmentSnapshotV2 {
  let n = self.runtimes.length()
  guard n > 0 else { fail("empty physical environment") }
  let cache = [self.runtimes[0].integration()]
  let cached_env = [0]
  let width = cache[0].length()
  guard width > 0 && n.to_int64() * width.to_int64() <= 16777216L else {
    fail("MuJoCo integration checkpoint exceeds bounded numeric envelope")
  }
  let physics = @checkpoint_stream.write_f64le(
    directory,
    "environment.physics.f64le",
    [n, width],
    (offset, count) => {
      Array::makei(count, i => {
        let flat = offset.to_int() + i
        let e = flat / width
        if cached_env[0] != e {
          cache[0] = self.runtimes[e].integration()
          cached_env[0] = e
        }
        guard cache[0].length() == width else {
          fail("MuJoCo integration widths differ")
        }
        cache[0][flat % width]
      })
    },
  )
  // Per-world columns: previous action[29], xi[33], return, discounted return.
  let values = @checkpoint_stream.write_f64le(
    directory,
    "environment.values.f64le",
    [n, 64],
    (offset, count) => {
      Array::makei(count, i => {
        let flat = offset.to_int() + i
        let e = flat / 64
        let j = flat % 64
        if j < 29 {
          self.previous[e][j]
        } else if j < 62 {
          self.xi[e][j - 29]
        } else if j == 62 {
          self.returns[e]
        } else {
          self.discounted[e]
        }
      })
    },
  )
  let indices = @checkpoint_stream.write_i32le(
    directory,
    "environment.indices.i32le",
    [n, 3],
    (offset, count) => {
      Array::makei(count, i => {
        let flat = offset.to_int() + i
        let e = flat / 3
        match flat % 3 {
          0 => self.frames[e]
          1 => self.episode_steps[e]
          _ => self.start_bins[e]
        }
      })
    },
  )
  let initialized = @checkpoint_stream.write_u8(
    directory,
    "environment.initialized.u8",
    [n],
    (offset, count) => {
      Array::makei(count, i => {
        if self.initialized[offset.to_int() + i] {
          b'\x01'
        } else {
          b'\x00'
        }
      })
    },
  )
  let sampler = self.sampler.write_checkpoint_v2(directory)
  {
    format: "moonrobo.aligned.mujoco-stream.v2",
    config: self.config,
    num_envs: n,
    integration_width: width,
    physics,
    values,
    indices,
    initialized,
    sampler,
    rng: self.rng.state(),
  }
}

///|
pub async fn Environment::restore_v2(
  self : Environment,
  directory : String,
  saved : EnvironmentSnapshotV2,
) -> Bool {
  let n = self.runtimes.length()
  let width = saved.integration_width
  guard saved.format == "moonrobo.aligned.mujoco-stream.v2" &&
    saved.config.to_json() == self.config.to_json() &&
    saved.num_envs == n &&
    saved.rng != 0U &&
    width > 0 &&
    n.to_int64() * width.to_int64() <= 16777216L &&
    self.runtimes.all(rt => rt.integration().length() == width) else {
    fail("MuJoCo stream checkpoint configuration differs")
  }
  @aligned.checkpoint_blob(
    saved.physics,
    "environment.physics.f64le",
    "f64le",
    [n, width],
  )
  @aligned.checkpoint_blob(saved.values, "environment.values.f64le", "f64le", [
    n, 64,
  ])
  @aligned.checkpoint_blob(
    saved.indices,
    "environment.indices.i32le",
    "i32le",
    [n, 3],
  )
  @aligned.checkpoint_blob(
    saved.initialized,
    "environment.initialized.u8",
    "u8",
    [n],
  )
  for blob in saved.blobs() {
    @checkpoint_stream.verify_blob(directory, blob)
  }
  let physics = @aligned.checkpoint_read_f64(
    directory,
    saved.physics,
    n * width,
  )
  let values = @aligned.checkpoint_read_f64(directory, saved.values, n * 64)
  let indices = @aligned.checkpoint_read_i32(directory, saved.indices, n * 3)
  let initialized = @aligned.checkpoint_read_u8(directory, saved.initialized, n)
  for e in 0..<n {
    guard indices[e * 3] >= 0 &&
      indices[e * 3] < self.motion.states.length() &&
      valid_checkpoint_episode_step(indices[e * 3 + 1], self.config) &&
      indices[e * 3 + 2] >= 0 &&
      indices[e * 3 + 2] < self.motion.bins.length() &&
      values[e * 64 + 29] > 0.0 &&
      (initialized[e] == b'\x00' || initialized[e] == b'\x01') else {
      fail("invalid physical stream episode/context fields")
    }
  }
  let sampler = self.sampler.prepare_checkpoint_v2(directory, saved.sampler)
  // All file decoding and business validation finish before live mutations.
  self.sampler.commit_checkpoint_v2(sampler)
  self.rng.set_state(saved.rng)
  let mut exact = true
  for e, rt in self.runtimes {
    let p = physics[e * width:(e + 1) * width].to_owned()
    let xi = values[e * 64 + 29:e * 64 + 62].to_owned()
    rt.set_friction(xi[0])
    rt.set_ground_friction(if self.config.eval_mode { 1.0 } else { 0.3 })
    rt.set_torso_com_offset(xi[30:33].to_owned())
    rt.set_integration(p)
    exact = exact && rt.integration() == p
    self.frames[e] = indices[e * 3]
    self.episode_steps[e] = indices[e * 3 + 1]
    self.start_bins[e] = indices[e * 3 + 2]
    self.previous[e] = values[e * 64:e * 64 + 29].to_owned()
    self.xi[e] = xi
    self.initialized[e] = initialized[e] == b'\x01'
    self.returns[e] = values[e * 64 + 62]
    self.discounted[e] = values[e * 64 + 63]
  }
  if !exact {
    self.reset()
  }
  exact
}
