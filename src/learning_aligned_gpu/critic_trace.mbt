///|
// Package-private, single-use recorder. No tensor or native optimizer handles
// survive a capture: only bounded CPU copies and small metadata are retained.
struct CriticTraceValue {
  name : String
  source_dtype : String
  shape : Array[Int32]
  values : Array[Double]
}

///|
enum CriticTracePhase {
  New
  Bound
  Prepared
  BootstrapCaptured
  Ready
  ForwardCaptured
  BeforeCaptured
  Complete
} derive(Eq, Debug)

///|
struct CriticTrace {
  rows : Int32
  records : Array[CriticTraceValue]
  adam_metadata : Array[Json]
  mut used_values : Int32
  mut completed_steps : Int32
  mut phase : CriticTracePhase
  mut norm_count : Double
  mut norm_epsilon : Double
}

///|
fn CriticTrace::new(rows : Int32) -> CriticTrace raise {
  guard rows > 0 && rows <= 256 else {
    fail("critic trace row bound is 1..256")
  }
  {
    rows,
    records: [],
    adam_metadata: [],
    used_values: 0,
    completed_steps: 0,
    phase: New,
    norm_count: 0.0,
    norm_epsilon: 0.0,
  }
}

///|
fn critic_trace_count(shape : Array[Int32]) -> Int32 raise {
  guard shape.length() <= 2 else {
    fail("critic trace accepts scalar/vector/matrix")
  }
  let mut count = 1
  for dim in shape {
    guard dim > 0 && count <= 120648 / dim else {
      fail("critic trace member exceeds 132x914 values")
    }
    count *= dim
  }
  count
}

///|
fn CriticTrace::capture(
  self : CriticTrace,
  name : String,
  value : @tensor.Tensor,
  expected_shape : Array[Int32],
  integer~ : Bool = false,
) -> Unit raise {
  let count = critic_trace_count(expected_shape)
  guard self.records.length() < 256 &&
    self.used_values <= 1048576 - count &&
    !self.records.any(record => record.name == name) &&
    value.shape() == expected_shape &&
    value.dtype() == (if integer { Int64 } else { Float32 }) else {
    fail("critic trace shape/dtype/duplicate/8MiB numeric budget rejected")
  }
  let flat = value.stop_gradient().reshape([-1])
  let values : Array[Double] = []
  for offset = 0; offset < count; {
    let size = (count - offset).min(8192)
    let part = flat.narrow(0, offset, size).values()
    guard part.length() == size && part.all(@numeric.finite) else {
      fail("nonfinite or incomplete critic trace transfer")
    }
    values.append(part)
    continue offset + size
  }
  self.records.push({
    name,
    source_dtype: if integer {
      "int64-exact-small-index"
    } else {
      "float32"
    },
    shape: expected_shape.copy(),
    values,
  })
  self.used_values += count
}

///|
fn CriticTrace::bind(
  self : CriticTrace,
  learner : Learner,
  batch : Int32,
  train_critic : Bool,
) -> Unit raise {
  let c = learner.config
  guard self.phase == New &&
    train_critic &&
    learner.collective is None &&
    batch == 4 &&
    c.horizon == 32 &&
    c.wm_window == 8 &&
    c.hist == 10 &&
    c.goal_frames == 10 &&
    c.critic_epochs == 5 &&
    c.critic_minibatches == 4 &&
    learner.critic.norm.count == 0.0 &&
    learner.critic.net.parameters()[0].shape() == [self.rows, 914] else {
    fail(
      "critic trace requires fresh single-rank B4/K8/H32/10 history/preview/20-step profile",
    )
  }
  let metadata : AdamAuditMetadata = @json.from_json(
    @json.parse(learner.opt_critic.audit_metadata()),
  )
  guard metadata.states.all(state => !state.present) else {
    fail("critic trace only accepts the first critic update")
  }
  self.phase = Bound
}

///|
fn CriticTrace::prepare(
  self : CriticTrace,
  learner : Learner,
  input : @tensor.Tensor,
  rewards : @tensor.Tensor,
  failures : @tensor.Tensor,
  orders : Array[@tensor.Tensor],
) -> Unit raise {
  guard self.phase == Bound && orders.length() == 5 else {
    fail("critic trace preparation order differs")
  }
  self.capture("raw-input", input, [132, 914])
  self.capture("norm-mean", learner.critic.norm.mean, [914])
  self.capture("norm-variance", learner.critic.norm.variance, [914])
  self.capture("rewards", rewards, [32, 4])
  self.capture("failures", failures, [32, 4])
  for i, order in orders {
    self.capture("order-\{i}", order, [128], integer=true)
    let values = self.records[self.records.length() - 1].values
    let seen = Array::make(128, false)
    for value in values {
      let index = value.to_int()
      guard index >= 0 &&
        index < 128 &&
        value == index.to_double() &&
        !seen[index] else {
        fail("critic trace requires exact permutation of all 128 samples")
      }
      seen[index] = true
    }
  }
  self.norm_count = learner.critic.norm.count
  self.norm_epsilon = learner.critic.norm.eps
  self.phase = Prepared
}

///|
// Called with the very tensor passed to Network::forward, never a second
// normalization or an extra probe. Captures all 914 columns per actual minibatch.
fn CriticTrace::normalized(
  self : CriticTrace,
  normalized : @tensor.Tensor,
  bootstrap : Bool,
) -> Unit raise {
  if bootstrap {
    guard self.phase == Prepared else { fail("unexpected trace bootstrap") }
    self.capture("bootstrap-normalized-input", normalized, [132, 914])
    self.phase = BootstrapCaptured
  } else {
    guard self.phase == Ready && self.completed_steps < 20 else {
      fail("unexpected trace training forward")
    }
    self.capture("step-\{self.completed_steps}-normalized-input", normalized, [
      32, 914,
    ])
    self.phase = ForwardCaptured
  }
}

///|
fn CriticTrace::targets(
  self : CriticTrace,
  values : @tensor.Tensor,
  targets : @tensor.Tensor,
) -> Unit raise {
  guard self.phase == BootstrapCaptured else {
    fail("trace targets out of order")
  }
  self.capture("bootstrap-values", values, [33, 4])
  self.capture("gae-targets", targets, [128])
  self.phase = Ready
}

///|
fn CriticTrace::optimizer_state(
  self : CriticTrace,
  learner : Learner,
  before : Bool,
) -> Unit raise {
  let step = self.completed_steps
  let label = if before { "before" } else { "after" }
  let expected_step = if before { step } else { step + 1 }
  let metadata : AdamAuditMetadata = @json.from_json(
    @json.parse(learner.opt_critic.audit_metadata()),
  )
  guard metadata.states.length() == metadata.parameter_count &&
    metadata.states.all(state => {
      if expected_step == 0 {
        !state.present
      } else {
        state.present && state.step == expected_step.to_int64()
      }
    }) else {
    fail("critic trace Adam step sequence differs")
  }
  self.adam_metadata.push({
    "step": Json(step),
    "position": Json(label),
    "adam": Json(metadata),
  })
  let prefix = "step-\{step}-\{label}"
  let parameter = learner.critic.net.parameters()[0]
  self.capture(prefix + "-weight", parameter.narrow(1, 146, 2), [self.rows, 2])
  self.capture(prefix + "-gradient", parameter.gradient().narrow(1, 146, 2), [
    self.rows,
    2,
  ])
  if expected_step > 0 {
    self.capture(
      prefix + "-m",
      learner.opt_critic.audit_tensor(0, kind=1).narrow(1, 146, 2),
      [self.rows, 2],
    )
    self.capture(
      prefix + "-v",
      learner.opt_critic.audit_tensor(0, kind=2).narrow(1, 146, 2),
      [self.rows, 2],
    )
  }
}

///|
fn CriticTrace::before_step(
  self : CriticTrace,
  learner : Learner,
  index : @tensor.Tensor,
  targets : @tensor.Tensor,
  loss : @tensor.Tensor,
) -> Unit raise {
  guard self.phase == ForwardCaptured else {
    fail("trace before-step out of order")
  }
  let prefix = "step-\{self.completed_steps}"
  self.capture(prefix + "-indices", index, [32], integer=true)
  self.capture(prefix + "-targets", targets, [32])
  self.capture(prefix + "-loss", loss, [])
  self.optimizer_state(learner, true)
  self.phase = BeforeCaptured
}

///|
fn CriticTrace::after_step(self : CriticTrace, learner : Learner) -> Unit raise {
  guard self.phase == BeforeCaptured else {
    fail("trace after-step out of order")
  }
  self.optimizer_state(learner, false)
  self.completed_steps += 1
  self.phase = if self.completed_steps == 20 { Complete } else { Ready }
}

///|
fn CriticTrace::finish(self : CriticTrace) -> Unit raise {
  guard self.phase == Complete &&
    self.completed_steps == 20 &&
    self.records.length() == 251 &&
    self.adam_metadata.length() == 40 &&
    self.used_values <= 1048576 else {
    fail("critic trace incomplete or exceeds fixed bounds")
  }
}
