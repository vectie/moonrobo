///|
pub(all) struct SamplerCheckpointV2 {
  format : String
  gamma : Double
  g_max : Double
  bins : Int32
  returns : @checkpoint_stream.BlobDescriptor
  average : @checkpoint_stream.BlobDescriptor
  completed : @checkpoint_stream.BlobDescriptor
} derive(ToJson, FromJson)

///|
pub fn SamplerCheckpointV2::blobs(
  self : SamplerCheckpointV2,
) -> Array[@checkpoint_stream.BlobDescriptor] {
  [self.returns, self.average, self.completed]
}

///|
pub struct SamplerRestoreV2 {
  priv gamma : Double
  priv g_max : Double
  priv returns : Array[Double]
  priv average : Array[Double]
  priv completed : Array[Int32]
}

///|
pub async fn ReturnBinSampler::write_checkpoint_v2(
  self : ReturnBinSampler,
  directory : String,
) -> SamplerCheckpointV2 {
  let n = self.bins.length()
  let returns = @checkpoint_stream.write_f64le(
    directory,
    "sampler.returns.f64le",
    [n],
    (offset, count) => {
      Array::makei(count, i => self.returns[offset.to_int() + i])
    },
  )
  let average = @checkpoint_stream.write_f64le(
    directory,
    "sampler.average.f64le",
    [n],
    (offset, count) => {
      Array::makei(count, i => self.average[offset.to_int() + i])
    },
  )
  let completed = @checkpoint_stream.write_i32le(
    directory,
    "sampler.completed.i32le",
    [n],
    (offset, count) => {
      Array::makei(count, i => self.completed[offset.to_int() + i])
    },
  )
  {
    format: "moonrobo.return-sampler-stream.v2",
    gamma: self.gamma,
    g_max: self.g_max,
    bins: n,
    returns,
    average,
    completed,
  }
}

///|
/// Hold one isolated copy of the three already-resident sampler arrays. No live
/// sampler is mutated until every environment and runtime blob has validated.
pub async fn ReturnBinSampler::prepare_checkpoint_v2(
  self : ReturnBinSampler,
  directory : String,
  saved : SamplerCheckpointV2,
) -> SamplerRestoreV2 {
  let n = self.bins.length()
  guard saved.format == "moonrobo.return-sampler-stream.v2" &&
    saved.bins == n &&
    saved.gamma == self.gamma &&
    saved.g_max == self.g_max else {
    fail("sampler checkpoint configuration differs")
  }
  checkpoint_blob(saved.returns, "sampler.returns.f64le", "f64le", [n])
  checkpoint_blob(saved.average, "sampler.average.f64le", "f64le", [n])
  checkpoint_blob(saved.completed, "sampler.completed.i32le", "i32le", [n])
  let returns = checkpoint_read_f64(directory, saved.returns, n)
  let average = checkpoint_read_f64(directory, saved.average, n)
  let completed = checkpoint_read_i32(directory, saved.completed, n)
  guard average.all(x => x >= 0.0) &&
    average.any(x => x > 0.0) &&
    completed.all(x => x >= 0) else {
    fail("invalid sampler checkpoint moments/counts")
  }
  let historical = average.fold(init=0.0, (a, b) => a + b)
  guard @numeric.finite(historical) && historical > 0.0 else {
    fail("sampler checkpoint historical probability sum is invalid")
  }
  // Finite returns can still overflow the original -25*return/g_max formula.
  // Exercise the same mathematics on isolated arrays before any warm reset.
  let candidate : ReturnBinSampler = {
    gamma: self.gamma,
    g_max: self.g_max,
    bins: self.bins,
    returns,
    average,
    completed,
  }
  let probabilities = candidate.probabilities()
  guard probabilities.all(p => @numeric.finite(p) && p >= 0.0) else {
    fail("sampler checkpoint produces nonfinite reset probabilities")
  }
  let mut usable = 0.0
  for i, bin in self.bins {
    if (bin.start + 50).min(bin.clip_end) > bin.start {
      usable += probabilities[i]
    }
  }
  guard @numeric.finite(usable) && usable > 0.0 else {
    fail("sampler checkpoint has no finite positive eligible reset mass")
  }
  { gamma: saved.gamma, g_max: saved.g_max, returns, average, completed, }
}

///|
pub fn ReturnBinSampler::commit_checkpoint_v2(
  self : ReturnBinSampler,
  staged : SamplerRestoreV2,
) -> Unit raise {
  guard staged.gamma == self.gamma && staged.g_max == self.g_max else {
    fail("prepared sampler belongs to another configuration")
  }
  self.restore(staged.returns, staged.average, staged.completed)
}
