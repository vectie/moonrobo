///|
/// Complete inference bundle with frozen temporal parent, fitted feedback, geometry and episode-local observer convention.
pub(all) struct BalancePolicy {
  parent : @temporal.TemporalPolicy
  head : @balance.FeedbackHead
  geometry : @balance.Kinematics
  dt : Double
  window : Int32?
} derive(Debug)

///|
pub fn BalancePolicy::checkpoint(
  self : BalancePolicy,
  provenance : Json,
) -> @artifacts.Checkpoint raise {
  let kind = match self.head {
    Learned(_) => "learned-balance-actor"
    Sustained(_) => "sustained-balance-actor"
  }
  @artifacts.Checkpoint::new(kind, {
    "parent": self.parent.checkpoint({ "frozen": true }).to_json(),
    "head": self.head.to_json(),
    "kinematics": self.geometry.to_json(),
    "dt_s": self.dt.to_json(),
    "window": self.window.to_json(),
    "transport": "gravity_gyro",
    "provenance": provenance,
    "physical_execution_allowed": false,
    "numeric_precision": "float64",
  })
}

///|
fn field(value : Json, name : String) -> Json raise {
  guard value is Object(fields) && fields.get(name) is Some(result) else {
    fail("missing balance policy field: " + name)
  }
  result
}

///|
pub fn from_checkpoint(
  checkpoint : @artifacts.Checkpoint,
) -> BalancePolicy raise {
  checkpoint.validate()
  guard checkpoint.model_kind == "learned-balance-actor" ||
    checkpoint.model_kind == "sustained-balance-actor" else {
    fail("expected complete balance policy checkpoint")
  }
  let metadata = checkpoint.metadata
  let parent_checkpoint : @artifacts.Checkpoint = @json.from_json(
    field(metadata, "parent"),
  )
  let parent = @temporal.temporal_from_checkpoint(parent_checkpoint)
  let head : @balance.FeedbackHead = @json.from_json(field(metadata, "head"))
  guard (match head {
    Learned(_) => checkpoint.model_kind == "learned-balance-actor"
    Sustained(_) => checkpoint.model_kind == "sustained-balance-actor"
  }) else {
    fail("checkpoint kind disagrees with feedback action mapping")
  }
  let geometry : @balance.Kinematics = @json.from_json(
    field(metadata, "kinematics"),
  )
  let dt : Double = @json.from_json(field(metadata, "dt_s"))
  let window : Int32? = @json.from_json(field(metadata, "window"))
  guard dt > 0.0 &&
    (match window {
      Some(n) => n > 0
      None => true
    }) &&
    geometry.nu == parent.base.lower.length() else {
    fail("invalid observer cadence, window or actuator geometry")
  }
  { parent, head, geometry, dt, window, }
}

///|
pub async fn save(
  path : String,
  policy : BalancePolicy,
  provenance : Json,
) -> String {
  @artifacts.save_checkpoint(path, policy.checkpoint(provenance))
}

///|
pub async fn load(path : String, sustained~ : Bool = false) -> BalancePolicy {
  if path.has_suffix(".pt") {
    from_torch_payload(@artifacts.load_torch_checkpoint(path), sustained)
  } else {
    from_checkpoint(
      @artifacts.load_checkpoint(
        path,
        if sustained {
          "sustained-balance-actor"
        } else {
          "learned-balance-actor"
        },
      ),
    )
  }
}

///|
/// Each call constructs fresh causal memory. Only the four ankle (and optional waist) outputs replace the frozen parent's control.
pub fn BalancePolicy::runner(
  self : BalancePolicy,
  reference : (Double) -> Array[Double],
) -> @balance.LearnedBalanceRunner {
  let parent = self.parent
  let temporal_runner = @temporal.TemporalRunner::new(
    parent.temporal,
    self.dt,
    reference,
    fn(obs, goal) {
      let tape = @numeric.Tape::new()
      parent.base
      .latent_mean(
        tape,
        parent.base.network.bind(tape),
        tape.vector(obs),
        tape.vector(goal),
      )
      .map(fn(v) { v.value })
    },
  )
  let history = match self.window {
    Some(n) => @balance.BalanceHistory::new(self.geometry, self.dt, window=n)
    None => @balance.BalanceHistory::full_memory(self.geometry, self.dt)
  }
  @balance.LearnedBalanceRunner::new(
    fn(obs, goal) { temporal_runner.predict(obs, goal) },
    self.head,
    history,
  )
}
