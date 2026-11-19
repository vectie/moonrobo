///|
fn state_rows(
  input : Map[String, @artifacts.NumericArray],
  prefix : String,
) -> Array[@aligned.State] raise {
  let p = rows(input, prefix + "p", 3)
  let r = rows(input, prefix + "R", 9)
  let v = rows(input, prefix + "v", 3)
  let w = rows(input, prefix + "w", 3)
  let q = rows(input, prefix + "q", 29)
  let qd = rows(input, prefix + "qd", 29)
  guard [r.length(), v.length(), w.length(), q.length(), qd.length()].all(n => {
    n == p.length()
  }) else {
    fail("MDP state batch lengths differ")
  }
  Array::makei(p.length(), i => {
    (
      { p: p[i], rotation: r[i], v: v[i], w: w[i], q: q[i], qd: qd[i], } :
      @aligned.State)
  })
}

///|
fn kinematics(
  input : Map[String, @artifacts.NumericArray],
) -> @aligned.Kinematics raise {
  let parent = get(input, "kin.parent").values
  let joints = get(input, "kin.joint").values
  let axes = rows(input, "kin.axis", 3)
  let offsets = rows(input, "kin.offset_p", 3)
  let rotations = rows(input, "kin.offset_R", 9)
  guard [joints.length(), axes.length(), offsets.length(), rotations.length()].all(n => {
      n == parent.length()
    },
  ) else {
    fail("static FK topology dimensions differ")
  }
  let bodies = Array::makei(parent.length(), i => {
    (
      {
        name: "source-bound-body-" + i.to_string(),
        parent: parent[i].to_int(),
        joint: joints[i].to_int(),
        axis: axes[i],
        offset_p: offsets[i],
        offset_rotation: rotations[i],
        pivot: [0.0, 0.0, 0.0],
        qref: 0.0,
      } : @aligned.BodySpec)
  })
  {
    bodies,
    tracked: get(input, "kin.tracked").values.map(x => x.to_int()),
    q_lo: get(input, "kin.q_lo").values,
    q_hi: get(input, "kin.q_hi").values,
  }
}

///|
fn flatten(values : Array[Array[Double]]) -> Array[Double] {
  let result = []
  for row in values {
    result.append(row)
  }
  result
}

///|
pub fn candidate_mdp(
  operation : String,
  input : Map[String, @artifacts.NumericArray],
) -> Map[String, @artifacts.NumericArray] raise {
  let output : Map[String, @artifacts.NumericArray] = {}
  if operation == "quaternion" {
    let vectors = rows(input, "inputs.vectors", 3)
    let weights = get(input, "inputs.quaternion_weights").values
    let pairs = vectors.map(v => @aligned.quaternion_pullback(v, weights))
    output["quaternion"] = array(
      [vectors.length(), 4],
      flatten(pairs.map(x => x.0)),
    )
    output["pullback"] = array(
      [vectors.length(), 3],
      flatten(pairs.map(x => x.1)),
    )
    output["finite"] = array(
      [],
      [if pairs.all(p => p.1.all(finite)) { 1.0 } else { 0.0 }],
      dtype="|b1",
    )
    return output
  }
  if operation == "rotation_fixes" {
    let (value, gradient) = @aligned.rotation_angle_pullback([0.00001, 0.0, 0.0])
    output["candidate_angle_sq"] = scalar(value)
    output["candidate_gradient"] = scalar(gradient[0])
    output["candidate_vertical_yaw"] = array(
      [3, 3],
      @aligned.yaw_mat([0.0, 0.0, 1.0, 0.0, 1.0, 0.0, -1.0, 0.0, 0.0]),
    )
    // Baseline fields must be supplied by the independent original-math oracle,
    // not recomputed with the corrected production implementation.
    return output
  }
  let kin = kinematics(input)
  let states = state_rows(input, "inputs.state.")
  if operation == "fk" {
    let body = states.map(s => kin.forward(s))
    let batch = states.length()
    let count = kin.tracked.length()
    for
      (key, width, data) in [
        ("body_p", 3, body.map(bs => flatten(bs.map(b => b.p)))),
        ("body_R", 9, body.map(bs => flatten(bs.map(b => b.rotation)))),
        ("body_v", 3, body.map(bs => flatten(bs.map(b => b.v)))),
        ("body_w", 3, body.map(bs => flatten(bs.map(b => b.w)))),
      ] {
      output[key] = array(
        if width == 9 {
          [batch, count, 3, 3]
        } else {
          [batch, count, 3]
        },
        flatten(data),
      )
    }
    return output
  }
  let references = state_rows(input, "reference.")
  let actions = rows(input, "inputs.action", 29)
  let previous = rows(input, "inputs.previous", 29)
  let xi = rows(input, "inputs.xi", 33)
  let defaults = get(input, "inputs.default_q").values
  if operation == "observation_modes" {
    for
      (name, mode) in [
        ("paper", @aligned.Paper),
        ("smc", @aligned.Smc),
        ("observable", @aligned.Observable),
      ] {
      let count = mode.dim().min(99)
      output[name] = array(
        [states.length(), count],
        flatten(
          states.mapi((i, s) => {
            @aligned.observation(
              s,
              previous[i],
              xi[i],
              defaults,
              references[i],
              mode,
            )[:count].to_owned()
          }),
        ),
      )
    }
    output["dimensions"] = array([3], [93.0, 99.0, 102.0], dtype="<i8")
    return output
  }
  guard operation == "mdp_heads" else {
    fail("unknown candidate MDP operation")
  }
  let bp = rows(input, "reference.body_p", 3)
  let br = rows(input, "reference.body_R", 9)
  let bv = rows(input, "reference.body_v", 3)
  let bw = rows(input, "reference.body_w", 3)
  let body_count = kin.tracked.length()
  let vectors = rows(input, "inputs.rotation_vector", 3)
  let uniforms = rows(input, "inputs.observation_uniform", 99)
  let observations = []
  let noisy = []
  let failures = []
  let soft = []
  let rewards = []
  let critic = []
  let pg = []
  let rg = []
  let qg = []
  let terms : Map[String, Array[Double]] = {
    "track": [],
    "e_body_pos": [],
    "e_body_ori": [],
    "e_root_pos": [],
    "action_rate": [],
    "joint_limit": [],
  }
  for i, original in states {
    let s = {
      ..original,
      rotation: @aligned.mat_mul(
        @aligned.so3_exp(vectors[i]),
        references[i].rotation,
      ),
    }
    let bodies = Array::makei(body_count, j => {
      let index = i * body_count + j
      (
        { p: bp[index], rotation: br[index], v: bv[index], w: bw[index], } :
        @aligned.BodyState)
    })
    let obs = @aligned.observation(
      s,
      previous[i],
      xi[i],
      defaults,
      references[i],
      Smc,
    )
    observations.push(obs)
    let widths = @aligned.observation_noise(Smc)
    noisy.push(obs.mapi((j, x) => x + (2.0 * uniforms[i][j] - 1.0) * widths[j]))
    failures.push(
      if @aligned.termination(s, references[i]) {
        1.0
      } else {
        0.0
      },
    )
    soft.push(@aligned.soft_termination(s, references[i]))
    let reward = @aligned.reward(
      kin,
      s,
      references[i],
      bodies,
      actions[i],
      previous[i],
    )
    rewards.push(reward.reward)
    terms["track"].push(reward.track)
    terms["e_body_pos"].push(reward.body_pos)
    terms["e_body_ori"].push(reward.body_ori)
    terms["e_root_pos"].push(reward.root_pos)
    terms["action_rate"].push(reward.action_rate)
    terms["joint_limit"].push(reward.joint_limit)
    critic.push(@aligned.critic_features(kin, s, references[i], bodies, xi[i]))
    let (_, p, r, q) = @aligned.reward_pullback(
      kin,
      s,
      references[i],
      bodies,
      actions[i],
      previous[i],
      vectors[i],
    )
    pg.push(p)
    rg.push(r)
    qg.push(q)
  }
  let n = states.length()
  output["observation"] = array([n, 99], flatten(observations))
  output["noisy_observation"] = array([n, 99], flatten(noisy))
  output["termination"] = array([n], failures, dtype="|b1")
  output["soft_termination"] = array([n], soft)
  output["reward"] = array([n], rewards)
  for name, data in terms {
    output["term." + name] = array([n], data)
  }
  output["critic_features"] = array([n, 184], flatten(critic))
  output["gradient.p"] = array([n, 3], flatten(pg))
  output["gradient.rotation_vector"] = array([n, 3], flatten(rg))
  output["gradient.q"] = array([n, 29], flatten(qg))
  output
}
