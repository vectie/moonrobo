///|
priv struct ParameterSlot {
  name : String
  shape : Array[Int32]
  offset : Int32
  length : Int32
}

///|
fn array(
  shape : Array[Int32],
  values : Array[Double],
  dtype~ : String = "<f8",
) -> @artifacts.NumericArray {
  { shape, values, dtype, }
}

///|
fn scalar(value : Double) -> @artifacts.NumericArray {
  array([], [value])
}

///|
fn get(
  input : Map[String, @artifacts.NumericArray],
  name : String,
) -> @artifacts.NumericArray raise {
  guard input.get(name) is Some(value) else {
    fail("missing fixed differential input: " + name)
  }
  value
}

///|
fn number(
  input : Map[String, @artifacts.NumericArray],
  name : String,
  default? : Double,
) -> Double raise {
  let result = match input.get(name) {
    Some(value) => {
      guard value.shape.is_empty() && value.values.length() == 1 else {
        fail("configuration must be scalar: " + name)
      }
      value.values[0]
    }
    None =>
      match default {
        Some(value) => value
        None => fail("missing differential configuration " + name)
      }
  }
  guard finite(result) else { fail("nonfinite differential configuration") }
  if [
      "config.hist", "config.goal_frames", "config.horizon", "config.wm_window",
      "config.wm_batch", "config.pi_batch", "config.critic_epochs", "config.critic_minibatches",
      "config.sample_count", "config.replay_capacity",
    ].contains(name) {
    guard result >= 1.0 && result <= 4096.0 && result.trunc() == result else {
      fail("bounded positive integer configuration required: " + name)
    }
  }
  if name.has_suffix(".step") {
    guard result >= 0.0 && result <= 2147483647.0 && result.trunc() == result else {
      fail("Adam step must be a bounded nonnegative integer")
    }
  }
  result
}

///|
fn rows(
  input : Map[String, @artifacts.NumericArray],
  name : String,
  width : Int32,
) -> Array[Array[Double]] raise {
  let value = get(input, name)
  guard value.shape.last() == Some(width) && value.values.length() % width == 0 else {
    fail("fixed input last dimension mismatch: " + name)
  }
  Array::makei(value.values.length() / width, i => {
    value.values[i * width:(i + 1) * width].to_owned()
  })
}

///|
fn slots(
  net : @aligned.Network,
  prefix : String,
  offset~ : Int32 = 0,
) -> Array[ParameterSlot] {
  let output = []
  let mut cursor = offset
  for i in 0..<(net.dimensions.length() - 1) {
    let layer = i * (if net.layer_norm { 3 } else { 2 })
    let name = prefix + layer.to_string()
    let nin = net.dimensions[i]
    let nout = net.dimensions[i + 1]
    output.push({
      name: name + ".weight",
      shape: [nout, nin],
      offset: cursor,
      length: nout * nin,
    })
    cursor += nout * nin
    output.push({
      name: name + ".bias",
      shape: [nout],
      offset: cursor,
      length: nout,
    })
    cursor += nout
    if net.layer_norm && i < net.dimensions.length() - 2 {
      for suffix in [".weight", ".bias"] {
        output.push({
          name: prefix + (layer + 1).to_string() + suffix,
          shape: [nout],
          offset: cursor,
          length: nout,
        })
        cursor += nout
      }
    }
  }
  output
}

///|
fn policy_slots(learner : @aligned.Learner) -> Array[ParameterSlot] {
  let out = slots(learner.policy.encoder, "enc.")
  out.append(
    slots(
      learner.policy.decoder,
      "dec.",
      offset=learner.policy.encoder.parameters.length(),
    ),
  )
  out
}

///|
fn flat_parameters(
  learner : @aligned.Learner,
  model : String,
) -> Array[Double] raise {
  match model {
    "wm" => learner.wm.net.parameters.copy()
    "pi" => {
      let p = learner.policy.encoder.parameters.copy()
      p.append(learner.policy.decoder.parameters)
      p
    }
    "critic" => learner.critic.net.parameters.copy()
    _ => fail("unknown model")
  }
}

///|
fn model_slots(
  learner : @aligned.Learner,
  model : String,
) -> Array[ParameterSlot] raise {
  match model {
    "wm" => slots(learner.wm.net, "net.")
    "pi" => policy_slots(learner)
    "critic" => slots(learner.critic.net, "net.")
    _ => fail("unknown model")
  }
}

///|
fn network_hidden(
  input : Map[String, @artifacts.NumericArray],
  prefix : String,
  stride : Int32,
) -> Array[Int32] raise {
  let mut index = 0
  let widths = []
  for ;; {
    let name = prefix + index.to_string() + ".weight"
    match input.get(name) {
      None => break
      Some(weight) => {
        guard weight.shape.length() == 2 else {
          fail("linear weight must be rank2")
        }
        widths.push(weight.shape[0])
        index += stride
      }
    }
  }
  guard widths.length() >= 2 else {
    fail("differential network must include hidden/output layers: " + prefix)
  }
  widths[:widths.length() - 1].to_owned()
}

///|
fn build_learner(
  input : Map[String, @artifacts.NumericArray],
) -> @aligned.Learner raise {
  let config : @aligned.LearnerConfig = {
    wm_hidden: network_hidden(input, "weights.wm.net.", 3),
    policy_hidden: network_hidden(input, "weights.pi.enc.", 2),
    critic_hidden: network_hidden(input, "weights.critic.net.", 2),
    hist: number(input, "config.hist", default=10.0).to_int(),
    goal_frames: number(input, "config.goal_frames", default=10.0).to_int(),
    horizon: number(input, "config.horizon", default=32.0).to_int(),
    wm_window: number(input, "config.wm_window", default=8.0).to_int(),
    wm_batches: 1,
    wm_batch: number(input, "config.wm_batch", default=2.0).to_int(),
    policy_batch: number(input, "config.pi_batch", default=2.0).to_int(),
    learning_rate: number(input, "config.lr", default=0.0002),
    gamma: number(input, "config.gamma", default=0.99),
    lam: number(input, "config.lam", default=0.95),
    critic_epochs: number(input, "config.critic_epochs", default=2.0).to_int(),
    critic_minibatches: number(input, "config.critic_minibatches", default=4.0).to_int(),
    observation_noise: false,
  }
  guard config.wm_hidden == [16, 16, 16] &&
    config.policy_hidden == [16, 12] &&
    config.critic_hidden == [16, 8] else {
    fail(
      "original small differential network widths must be 16x3 / 16,12 / 16,8",
    )
  }
  let reference : @aligned.State = {
    p: [0.0, 0.0, 0.8],
    rotation: @aligned.identity(),
    v: Array::make(3, 0.0),
    w: Array::make(3, 0.0),
    q: Array::make(29, 0.0),
    qd: Array::make(29, 0.0),
  }
  let kin : @aligned.Kinematics = {
    bodies: [
      {
        name: "fixture-root",
        parent: -1,
        joint: -1,
        axis: [0.0, 0.0, 1.0],
        offset_p: [0.0, 0.0, 0.0],
        offset_rotation: @aligned.identity(),
        pivot: [0.0, 0.0, 0.0],
        qref: 0.0,
      },
    ],
    tracked: [0],
    q_lo: Array::make(29, -3.0),
    q_hi: Array::make(29, 3.0),
  }
  let motion : @aligned.MotionLibrary = {
    names: ["original-FixtureMotion"],
    source_sha256: ["source-bound-in-manifest"],
    source_fps: 30.0,
    states: @aligned.FrameStore::eager(Array::make(100, reference)),
    bodies: @aligned.FrameStore::eager(Array::make(100, kin.forward(reference))),
    clip_start: [0],
    clip_end: [99],
    clip_id: @aligned.FrameStore::eager(Array::make(100, 0)),
    bins: [{ start: 0, clip_end: 99, }],
    frame_bin: @aligned.FrameStore::eager(Array::make(100, 0)),
    orthonormal_heading: false,
  }
  let learner = @aligned.Learner::new(kin, motion, config~, seed=1U)
  let groups : Map[String, @artifacts.TorchValue] = {}
  for model in ["wm", "pi", "critic"] {
    let state : Map[String, @artifacts.TorchValue] = {}
    let prefix = "weights." + model + "."
    for name, tensor in input {
      if name.has_prefix(prefix) {
        state[name[prefix.length():].to_owned()] = TorchTensor(tensor)
      }
    }
    groups[model] = TorchDict(state)
  }
  learner.import_torch_weights(TorchDict(groups))
  for
    (name, opt) in [
      ("wm", learner.opt_wm),
      ("pi", learner.opt_policy),
      ("critic", learner.opt_critic),
    ] {
    let layout = model_slots(learner, name)
    let prefix = "optimizer_before." + name + "."
    if input.keys().any(key => key.has_prefix(prefix)) {
      let first = Array::make(opt.first.length(), 0.0)
      let second = first.copy()
      let mut step = None
      for slot in layout {
        let m = get(input, prefix + slot.name + ".exp_avg")
        let v = get(input, prefix + slot.name + ".exp_avg_sq")
        guard m.shape == slot.shape &&
          v.shape == slot.shape &&
          v.values.all(x => x >= 0.0) else {
          fail("Adam source shape or second moment differs")
        }
        let count = number(input, prefix + slot.name + ".step").to_int()
        if step is Some(previous) {
          guard previous == count else {
            fail(
              "native Adam requires uniform per-parameter step; heterogeneous Torch state not silently coerced",
            )
          }
        } else {
          step = Some(count)
        }
        for j in 0..<slot.length {
          first[slot.offset + j] = m.values[j]
          second[slot.offset + j] = v.values[j]
        }
      }
      let saved : @numeric.Adam = @json.from_json({
        "first": first,
        "second": second,
        "steps": step.unwrap_or(0),
        "learning_rate": opt.learning_rate,
        "beta1": opt.beta1,
        "beta2": opt.beta2,
        "epsilon": opt.epsilon,
      })
      opt.restore(saved)
    }
  }
  learner
}

///|
fn export_norm(
  output : Map[String, @artifacts.NumericArray],
  prefix : String,
  norm : @aligned.RunningNorm,
) -> Unit {
  output[prefix + ".mean"] = array([norm.mean.length()], norm.mean.copy())
  output[prefix + ".var"] = array(
    [norm.variance.length()],
    norm.variance.copy(),
  )
  output[prefix + ".count"] = scalar(norm.count)
}

///|
fn export_model(
  output : Map[String, @artifacts.NumericArray],
  learner : @aligned.Learner,
  model : String,
) -> Unit raise {
  let parameters = flat_parameters(learner, model)
  for slot in model_slots(learner, model) {
    output["weights_after." + model + "." + slot.name] = array(
      slot.shape,
      parameters[slot.offset:slot.offset + slot.length].to_owned(),
    )
  }
  match model {
    "wm" => {
      export_norm(output, "weights_after.wm.in_norm", learner.wm.input_norm)
      export_norm(output, "weights_after.wm.out_norm", learner.wm.output_norm)
    }
    "pi" => {
      export_norm(output, "weights_after.pi.obs_norm", learner.policy.obs_norm)
      export_norm(
        output,
        "weights_after.pi.goal_norm",
        learner.policy.goal_norm,
      )
    }
    "critic" =>
      export_norm(output, "weights_after.critic.norm", learner.critic.norm)
    _ => fail("unknown export model")
  }
}

///|
fn export_optimizer(
  output : Map[String, @artifacts.NumericArray],
  learner : @aligned.Learner,
  model : String,
  optimizer : @numeric.Adam,
) -> Unit raise {
  for slot in model_slots(learner, model) {
    let prefix = "optimizer_after." + model + "." + slot.name
    output[prefix + ".exp_avg"] = array(
      slot.shape,
      optimizer.first[slot.offset:slot.offset + slot.length].to_owned(),
    )
    output[prefix + ".exp_avg_sq"] = array(
      slot.shape,
      optimizer.second[slot.offset:slot.offset + slot.length].to_owned(),
    )
    output[prefix + ".step"] = scalar(optimizer.steps.to_double())
  }
}

///|
fn capture_gradient(
  output : Map[String, @artifacts.NumericArray],
  learner : @aligned.Learner,
  kind : String,
  index : Int32,
  raw : Array[Double],
  clipped : Array[Double],
) -> Unit raise {
  let model = if kind == "world" {
    "wm"
  } else if kind == "policy" {
    "pi"
  } else {
    "critic"
  }
  let stage = if model == "critic" {
    "step" + index.to_string() + "."
  } else {
    ""
  }
  for slot in model_slots(learner, model) {
    for (prefix, gradient) in [("grad.raw.", raw), ("grad.clipped.", clipped)] {
      output[prefix + model + "." + stage + slot.name] = array(
        slot.shape,
        gradient[slot.offset:slot.offset + slot.length].to_owned(),
      )
    }
  }
}

///|
fn transition(
  s : Array[Double],
  s1 : Array[Double],
  action : Array[Double],
  previous : Array[Double],
  xi : Array[Double],
  frame : Int32,
  ep_step : Int32,
  done~ : Bool = false,
) -> @aligned.Transition {
  {
    s,
    s1,
    a: action,
    a_prev: previous,
    xi,
    r: 0.0,
    frame,
    ep_step,
    terminated: done,
    truncated: false,
  }
}

///|
pub fn candidate_learning(
  operation : String,
  input : Map[String, @artifacts.NumericArray],
) -> Map[String, @artifacts.NumericArray] raise {
  let learner = build_learner(input)
  let output : Map[String, @artifacts.NumericArray] = {}
  if operation == "network" {
    let states = rows(input, "inputs.state", 71)
    let actions = rows(input, "inputs.action", 29)
    let xi = rows(input, "inputs.xi_normalized", 33)
    let predicted = states.mapi((i, s) => {
      learner.wm.step(@aligned.unflatten_state(s), actions[i], xi[i])
    })
    for
      (name, width, values) in [
        ("p", 3, predicted.map(s => s.p)),
        ("R", 9, predicted.map(s => s.rotation)),
        ("v", 3, predicted.map(s => s.v)),
        ("w", 3, predicted.map(s => s.w)),
        ("q", 29, predicted.map(s => s.q)),
        ("qd", 29, predicted.map(s => s.qd)),
      ] {
      let flat = []
      for row in values {
        flat.append(row)
      }
      output["network.world." + name] = array(
        if name == "R" {
          [states.length(), 3, 3]
        } else {
          [states.length(), width]
        },
        flat,
      )
    }
    let history = rows(input, "inputs.observation_history", 93)
    let goals = rows(input, "inputs.goal", 730)
    let policy = []
    for i in 0..<goals.length() {
      policy.append(
        learner.policy.forward(
          history[i * 10:(i + 1) * 10].to_owned(),
          goals[i],
        ),
      )
    }
    output["network.policy"] = array([goals.length(), 29], policy)
    let critic = rows(input, "inputs.critic_features", 914)
    output["network.critic"] = array(
      [critic.length()],
      critic.map(x => learner.critic.predict(x)),
    )
  } else if operation == "world_update" {
    let ss = rows(input, "inputs.windows.s", 71)
    let next = rows(input, "inputs.windows.s1", 71)
    let actions = rows(input, "inputs.windows.a", 29)
    let xi = rows(input, "inputs.windows.xi", 33)
    let mask = get(input, "inputs.windows.mask")
    let batch = mask.shape[0]
    let horizon = mask.shape[1]
    let windows = Array::makei(batch, b => {
      (
        {
          transitions: Array::makei(horizon, j => {
            let i = b * horizon + j
            transition(
              ss[i],
              next[i],
              actions[i],
              Array::make(29, 0.0),
              xi[i],
              j,
              j,
            )
          }),
          mask: mask.values[b * horizon:(b + 1) * horizon].to_owned(),
        } : @aligned.ReplayWindow)
    })
    let result = learner.wm.fit_fixed(windows, learner.opt_wm, gradient_trace=(
      kind,
      index,
      raw,
      clipped,
      _,
    ) => try! capture_gradient(output, learner, kind, index, raw, clipped))
    output["metrics.wm_loss"] = scalar(result.loss)
    output["metrics.wm_err8"] = scalar(result.last_error)
    export_model(output, learner, "wm")
    export_optimizer(output, learner, "wm", learner.opt_wm)
  } else if operation == "policy_update" {
    let ss = rows(input, "inputs.starts.s", 71)
    let previous = rows(input, "inputs.starts.a_prev", 29)
    let xi = rows(input, "inputs.starts.xi", 33)
    let frames = get(input, "inputs.starts.f").values
    let hs = rows(input, "inputs.history.s", 71)
    let ha = rows(input, "inputs.history.a_prev", 29)
    let hx = rows(input, "inputs.history.xi", 33)
    let hf = get(input, "inputs.history.f").values
    let hist = learner.config.hist
    let starts = Array::makei(ss.length(), b => {
      (
        {
          start: transition(
            ss[b],
            ss[b],
            Array::make(29, 0.0),
            previous[b],
            xi[b],
            frames[b].to_int(),
            0,
          ),
          history: Array::makei(hist, j => {
            let i = b * hist + j
            transition(
              hs[i],
              hs[i],
              Array::make(29, 0.0),
              ha[i],
              hx[i],
              hf[i].to_int(),
              j,
            )
          }),
        } : @aligned.ReplayStart)
    })
    let permutations = get(input, "inputs.critic_permutations")
    guard permutations.shape ==
      [learner.config.critic_epochs, learner.config.horizon * ss.length()] else {
      fail("critic permutations shape differs from original contract")
    }
    let n = learner.config.horizon * ss.length()
    let fixed : @aligned.FixedPolicyBatch = {
      starts,
      goals: Array::makei(learner.config.horizon + 1, _ => {
        Array::makei(ss.length(), _ => Array::make(730, 0.01))
      }),
      critic_permutations: Array::makei(learner.config.critic_epochs, i => {
        permutations.values[i * n:(i + 1) * n].map(x => x.to_int())
      }),
      heads: FixtureHeads,
    }
    let result = learner.update_policy_fixed(fixed, gradient_trace=(
      kind,
      index,
      raw,
      clipped,
      _,
    ) => try! capture_gradient(output, learner, kind, index, raw, clipped))
    output["metrics.pi_loss"] = scalar(result.policy_loss)
    output["metrics.imag_rew"] = scalar(result.imagined_reward)
    output["metrics.pi_gradnorm"] = scalar(result.gradient_norm)
    output["metrics.imag_survival"] = scalar(result.imagined_survival)
    for model in ["wm", "pi", "critic"] {
      export_model(output, learner, model)
    }
    export_optimizer(output, learner, "pi", learner.opt_policy)
    export_optimizer(output, learner, "critic", learner.opt_critic)
  } else {
    fail("unknown learning differential operation")
  }
  output
}
