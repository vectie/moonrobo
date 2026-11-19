///|
struct WeightIndex {
  format : String
  norm_counts : Array[Int64]
  updates : Int32
  physical_steps : Int32
} derive(ToJson, @json.FromJson)

///|
fn Optimizer::checkpoint(
  self : Optimizer,
  prefix : String,
  load~ : Bool,
) -> Unit raise {
  if load {
    self.adam.load(prefix + ".adam")
  } else {
    self.adam.save(prefix + ".adam")
  }
  for i, (w, buf) in self.muon {
    w.checkpoint(prefix + ".muon-" + i.to_string() + ".weight", load~)
    buf.checkpoint(prefix + ".muon-" + i.to_string() + ".momentum", load~)
  }
}

///|
fn GenLearner::transfer(
  self : GenLearner,
  dir : String,
  load~ : Bool,
) -> Array[EmpiricalNorm] raise {
  let model = self.model
  model.scale.checkpoint(dir + "/action-scale", load~)
  model.offset.checkpoint(dir + "/action-offset", load~)
  self.world_optimizer.checkpoint(dir + "/world", load~)
  self.actor_optimizer.checkpoint(dir + "/actor", load~)
  self.critic_optimizer.checkpoint(dir + "/critic", load~)
  // The author's motion-only slot mix includes an inactive velocity encoder.
  for i, layer in model.velocity_encoder.layers {
    let prefix = dir + "/velocity-" + i.to_string()
    layer.weight.checkpoint(prefix + ".w", load~)
    layer.bias.checkpoint(prefix + ".b", load~)
    if layer.norm_weight is Some(nw) && layer.norm_bias is Some(nb) {
      nw.checkpoint(prefix + ".nw", load~)
      nb.checkpoint(prefix + ".nb", load~)
    }
  }
  let norms = [
    model.state_norm,
    model.action_norm,
    model.obs_norm,
    model.goal_norm,
    model.velocity_norm,
  ]
  for i, norm in norms {
    norm.mean.checkpoint(dir + "/mean-" + i.to_string(), load~)
    norm.variance.checkpoint(dir + "/variance-" + i.to_string(), load~)
  }
  norms
}

///|
/// A generation is readable after its complete index has been published.
/// Replay and physical simulation start fresh if warm-starting a new run.
pub fn GenLearner::save_weights(
  self : GenLearner,
  dir : String,
  updates : Int32,
  steps : Int32,
) -> Unit raise {
  guard !@fs.path_exists(dir) else {
    fail("checkpoint generation already exists")
  }
  @fs.create_dir(dir)
  let norms = self.transfer(dir, load=false)
  let info : WeightIndex = {
    format: "moonrobo.author-gencoord.weights.v2",
    norm_counts: norms.map(x => x.count),
    updates,
    physical_steps: steps,
  }
  @fs.write_string_to_file(dir + "/complete.json", info.to_json().stringify())
}

///|
pub fn GenLearner::load_weights(
  self : GenLearner,
  dir : String,
) -> (Int32, Int32) raise {
  let info : WeightIndex = @json.from_json(
    @json.parse(@fs.read_file_to_string(dir + "/complete.json")),
  )
  guard info.format == "moonrobo.author-gencoord.weights.v2" &&
    info.norm_counts.length() == 5 &&
    info.norm_counts.all(n => n >= 0L) else {
    fail("incompatible checkpoint")
  }
  let norms = self.transfer(dir, load=true)
  for i, n in norms {
    n.count = info.norm_counts[i]
  }
  (info.updates, info.physical_steps)
}
