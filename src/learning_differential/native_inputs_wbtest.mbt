///|
fn native_state(index : Int32) -> Array[Double] {
  let s = Array::make(71, 0.0)
  s[0] = 0.003 * index.to_double()
  s[2] = 0.8 + 0.001 * index.to_double()
  s[3] = 1.0
  for j in 0..<29 {
    s[13 + j] = 0.001 * (index + j).to_double()
    s[42 + j] = 0.01 * (j % 5 - 2).to_double()
  }
  s
}

///|
fn native_learning_input() -> Map[String, @artifacts.NumericArray] {
  let result : Map[String, @artifacts.NumericArray] = Map([])
  for
    (key, value) in [
      ("hist", 10.0),
      ("goal_frames", 10.0),
      ("horizon", 32.0),
      ("wm_window", 8.0),
      ("wm_batch", 2.0),
      ("pi_batch", 2.0),
      ("critic_epochs", 2.0),
      ("critic_minibatches", 4.0),
      ("lr", 0.0002),
      ("gamma", 0.99),
      ("lam", 0.95),
      ("no_critic", 0.0),
      ("observation_noise", 0.0),
    ] {
    result["config." + key] = scalar(value)
  }
  let layout = (dims : Array[Int32], prefix : String, norm : Bool) => {
    slots(
      (
        { dimensions: dims, parameters: [], activation: Elu, layer_norm: norm, } :
        @aligned.Network),
      prefix,
    )
  }
  for
    (model, groups, norms) in [
      (
        "wm",
        [layout([133, 16, 16, 16, 70], "net.", true)],
        [("in_norm", 133), ("out_norm", 70)],
      ),
      (
        "pi",
        [
          layout([730, 16, 12, 32], "enc.", false),
          layout([962, 16, 12, 29], "dec.", false),
        ],
        [("obs_norm", 93), ("goal_norm", 730)],
      ),
      ("critic", [layout([914, 16, 8, 1], "net.", false)], [("norm", 914)]),
    ] {
    for group in groups {
      for spec in group {
        let normalization = spec.shape.length() == 1 &&
          spec.name.has_prefix("net.") &&
          ["net.1.weight", "net.4.weight", "net.7.weight"].contains(spec.name)
        let values = Array::makei(spec.length, i => {
          if normalization {
            1.0 + 0.003 * (i % 3).to_double()
          } else {
            0.003 * ((i + spec.offset) % 19 - 9).to_double()
          }
        })
        result["weights." + model + "." + spec.name] = array(spec.shape, values)
        for moment in ["exp_avg", "exp_avg_sq"] {
          result["optimizer_before." + model + "." + spec.name + "." + moment] = array(
            spec.shape,
            Array::make(spec.length, 0.0),
          )
        }
        result["optimizer_before." + model + "." + spec.name + ".step"] = scalar(
          0.0,
        )
      }
    }
    for (name, width) in norms {
      result["weights." + model + "." + name + ".mean"] = array(
        [width],
        Array::makei(width, i => 0.002 * (i % 3).to_double()),
      )
      result["weights." + model + "." + name + ".var"] = array(
        [width],
        Array::makei(width, i => 0.8 + 0.01 * (i % 5).to_double()),
      )
      result["weights." + model + "." + name + ".count"] = scalar(16.0)
    }
  }
  result["inputs.state"] = array(
    [2, 71],
    flatten([native_state(1), native_state(2)]),
  )
  result["inputs.action"] = array(
    [2, 29],
    Array::makei(58, i => 0.001 * (i % 7 - 3).to_double()),
  )
  result["inputs.xi_normalized"] = array(
    [2, 33],
    Array::makei(66, i => 0.001 * (i % 5 - 2).to_double()),
  )
  result["inputs.observation_history"] = array(
    [2, 10, 93],
    Array::makei(1860, i => 0.01 * (i % 11 - 5).to_double()),
  )
  result["inputs.goal"] = array(
    [2, 730],
    Array::makei(1460, i => 0.005 * (i % 13 - 6).to_double()),
  )
  result["inputs.critic_features"] = array(
    [2, 914],
    Array::makei(1828, i => 0.01 * (i % 17 - 8).to_double()),
  )
  result["inputs.windows.s"] = array(
    [2, 8, 71],
    flatten(Array::makei(16, i => native_state(i))),
  )
  result["inputs.windows.s1"] = array(
    [2, 8, 71],
    flatten(Array::makei(16, i => native_state(i + 1))),
  )
  result["inputs.windows.a"] = array(
    [2, 8, 29],
    Array::makei(464, i => 0.005 * (i % 7 - 3).to_double()),
  )
  let contexts = Array::makei(16, _ => {
    let xi = Array::make(33, 0.0)
    xi[0] = 0.75
    xi
  })
  result["inputs.windows.xi"] = array([2, 8, 33], flatten(contexts))
  result["inputs.windows.mask"] = array(
    [2, 8],
    Array::makei(16, i => if i == 13 { 0.0 } else { 1.0 }),
  )
  result["inputs.error_floor"] = array(
    [70],
    Array::makei(70, i => {
      if i < 3 {
        0.003
      } else if i < 6 {
        0.005
      } else if i < 9 {
        0.02
      } else if i < 12 {
        0.05
      } else if i < 41 {
        0.003
      } else {
        0.05
      }
    }),
  )
  result["inputs.starts.s"] = result["inputs.state"]
  result["inputs.starts.a_prev"] = result["inputs.action"]
  result["inputs.starts.xi"] = array([2, 33], flatten(contexts[:2].to_owned()))
  result["inputs.starts.f"] = array([2], [15.0, 16.0], dtype="<i8")
  result["inputs.history.s"] = array(
    [2, 10, 71],
    flatten(Array::makei(20, i => native_state(i % 10))),
  )
  result["inputs.history.a_prev"] = array(
    [2, 10, 29],
    Array::makei(580, i => 0.001 * (i % 7 - 3).to_double()),
  )
  result["inputs.history.xi"] = array(
    [2, 10, 33],
    flatten(Array::makei(20, i => contexts[i % 16])),
  )
  result["inputs.history.f"] = array(
    [2, 10],
    Array::makei(20, i => (i % 10 + 5).to_double()),
    dtype="<i8",
  )
  result["inputs.critic_permutations"] = array(
    [2, 64],
    Array::makei(128, i => {
      if i < 64 {
        i.to_double()
      } else {
        (127 - i).to_double()
      }
    }),
    dtype="<i8",
  )
  result
}

///|
fn native_mdp_input() -> Map[String, @artifacts.NumericArray] {
  let x : Map[String, @artifacts.NumericArray] = Map([])
  for prefix in ["inputs.state.", "reference."] {
    let rotated = prefix == "inputs.state."
    x[prefix + "p"] = array([2, 3], [0.12, -0.08, 0.83, -0.05, 0.12, 0.76])
    x[prefix + "R"] = array(
      [2, 3, 3],
      flatten(
        if rotated {
          [
            @aligned.so3_exp([0.2, -0.15, 0.3]),
            @aligned.so3_exp([-0.1, 0.2, -0.3]),
          ]
        } else {
          [@aligned.identity(), @aligned.identity()]
        },
      ),
    )
    x[prefix + "v"] = array([2, 3], [0.03, 0.02, -0.01, -0.02, 0.04, 0.01])
    x[prefix + "w"] = array([2, 3], [0.01, -0.02, 0.03, 0.03, 0.01, -0.01])
    x[prefix + "q"] = array(
      [2, 29],
      Array::makei(58, i => 0.01 * (i % 9 - 4).to_double()),
    )
    x[prefix + "qd"] = array(
      [2, 29],
      Array::makei(58, i => 0.02 * (i % 5 - 2).to_double()),
    )
  }
  x["inputs.rotation_vector"] = array([2, 3], [0.2, -0.15, 0.3, -0.1, 0.2, -0.3])
  x["kin.parent"] = array([5], [-1.0, 0.0, 1.0, 0.0, 3.0], dtype="<i8")
  x["kin.joint"] = array([5], [-1.0, 0.0, 1.0, 2.0, 3.0], dtype="<i8")
  x["kin.axis"] = array([5, 3], [0.0, 0, 1, 0, 1, 0, 1, 0, 0, 0, 0, 1, 0, 1, 0])
  x["kin.offset_p"] = array([5, 3], [
    0.0, 0, 0, 0.03, 0.02, 0.01, 0.04, 0, 0.02, 0.02, -0.03, 0.01, 0.05, 0, 0,
  ])
  x["kin.offset_R"] = array(
    [5, 3, 3],
    flatten(Array::make(5, @aligned.identity())),
  )
  x["kin.tracked"] = array(
    [14],
    Array::makei(14, i => (i % 5).to_double()),
    dtype="<i8",
  )
  x["kin.q_lo"] = array([29], Array::make(29, -2.5))
  x["kin.q_hi"] = array([29], Array::make(29, 2.5))
  x["inputs.action"] = array(
    [2, 29],
    Array::makei(58, i => 0.01 * (i % 7 - 3).to_double()),
  )
  x["inputs.previous"] = array(
    [2, 29],
    Array::makei(58, i => 0.003 * (i % 11 - 5).to_double()),
  )
  x["inputs.default_q"] = array(
    [29],
    Array::makei(29, i => 0.005 * (i % 3).to_double()),
  )
  x["inputs.xi"] = array(
    [2, 33],
    Array::makei(66, i => {
      if i % 33 == 0 {
        0.75
      } else {
        0.001 * (i % 5 - 2).to_double()
      }
    }),
  )
  x["inputs.observation_uniform"] = array(
    [2, 99],
    Array::makei(198, i => (i % 17).to_double() / 17.0),
  )
  x["reference.body_p"] = array(
    [2, 14, 3],
    flatten(
      Array::makei(28, i => {
        [0.01 * (i % 5).to_double(), 0.005 * (i % 3).to_double(), 0.82]
      }),
    ),
  )
  x["reference.body_R"] = array(
    [2, 14, 3, 3],
    flatten(Array::make(28, @aligned.identity())),
  )
  x["reference.body_v"] = array([2, 14, 3], Array::make(84, 0.01))
  x["reference.body_w"] = array([2, 14, 3], Array::make(84, 0.02))
  x
}

///|
fn native_replay_input() -> Map[String, @artifacts.NumericArray] {
  let x : Map[String, @artifacts.NumericArray] = Map([])
  x["config.replay_capacity"] = scalar(8.0)
  x["replay.s"] = array(
    [15, 1, 71],
    flatten(
      Array::makei(15, i => native_state(if i < 10 { i } else { i + 20 })),
    ),
  )
  x["replay.s1"] = array(
    [15, 1, 71],
    flatten(
      Array::makei(15, i => native_state(if i < 10 { i + 1 } else { i + 21 })),
    ),
  )
  x["replay.a"] = array([15, 1, 29], Array::make(435, 0.02))
  x["replay.a_prev"] = array([15, 1, 29], Array::make(435, 0.0))
  x["replay.xi"] = array(
    [15, 1, 33],
    Array::makei(495, i => if i % 33 == 0 { 0.75 } else { 0.0 }),
  )
  x["replay.f"] = array(
    [15, 1],
    Array::makei(15, i => i.to_double()),
    dtype="<i8",
  )
  x["replay.ep_step"] = array(
    [15, 1],
    Array::makei(15, i => {
      if i < 10 {
        i.to_double()
      } else {
        (i - 10).to_double()
      }
    }),
    dtype="<i8",
  )
  x["replay.done"] = array(
    [15, 1],
    Array::makei(15, i => if i == 9 { 1.0 } else { 0.0 }),
    dtype="|b1",
  )
  x["inputs.window_ages"] = array([4], [0.0, 0, 0, 0], dtype="<i8")
  x["inputs.window_environments"] = array([4], [0.0, 0, 0, 0], dtype="<i8")
  x["inputs.start_ages"] = array([4], [0.0, 2, 3, 7], dtype="<i8")
  x["inputs.restore_ages"] = array(
    [20],
    Array::makei(20, i => (i % 8).to_double()),
    dtype="<i8",
  )
  x
}
