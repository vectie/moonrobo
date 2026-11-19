///|
fn near(
  actual : Array[Double],
  expected : Array[Double],
  tol : Double,
) -> Unit raise {
  assert_eq(actual.length(), expected.length())
  for i in 0..<actual.length() {
    assert_true(
      (actual[i] - expected[i]).abs() <= tol,
      msg="index \{i}: \{actual[i]} versus \{expected[i]}",
    )
  }
}

///|
test "GenCoord seven-step trajectory and shared increment gradient, upstream float64 CPU" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    return
  }
  let b = @tensor.Backend::open(path)
  let row = [
    0.1, -0.3, 0.7, 0.5, 0.5, -0.5, 0.5, 0.3, -0.9, 0.4, 0.2, 0.5, -0.3,
  ]
  row.append(Array::makei(29, i => i.to_double() / 49.0))
  row.append(Array::makei(29, i => i.to_double() / 83.0))
  let delta = b.from_values(
    [1, 35],
    Array::makei(35, i => i.to_double() / 117.0 - 0.12),
    cuda_device=-1,
    requires_grad=true,
    dtype=Float64,
  )
  let mut s = GenState::from_replay(
    b,
    b.from_values(
      [1, 71],
      row,
      cuda_device=-1,
      requires_grad=false,
      dtype=Float64,
    ),
  )
  for _ in 0..<7 {
    s = s.advance(b, delta, dt=0.02, decimation=4)
  }
  let aux = b.concat([s.position, s.quat], axis=1)
  near(
    aux.values(),
    [
      0.19800004422477838, -0.3739480021244614, 0.6944408355553325, 0.530373024110695,
      0.5210074005005777, -0.5114954558778052, 0.4308458454431969,
    ],
    1.0e-11,
  )
  let loss = aux.square().sum().add(s.reduced.square().sum())
  near(loss.values(), [30.33585301462429], 1.0e-10)
  loss.backward()
  let grad = delta.gradient().values()
  near(
    [0, 1, 2, 3, 4, 5, 6, 18, 34].map(i => grad[i]),
    [
      -4.269182908519318, -15.431866662747687, 2.591343330664069, -13.700138033696874,
      -11.098282050864793, -14.392289246001162, -6.76975644871795, 5.627570046273005,
      22.157338706260937,
    ],
    1.0e-9,
  )
}

///|
test "current frame and stride-five preview clamp to the current clip" {
  assert_eq(preview_frames(110, 165), [
    110, 115, 120, 125, 130, 135, 140, 145, 150, 155,
  ])
  assert_eq(preview_frames(110, 117), [
    110, 115, 117, 117, 117, 117, 117, 117, 117, 117,
  ])
}

///|
test "GenCoord learner fits world, actor and critic through LibTorch" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    return
  }
  let b = @tensor.Backend::open(path)
  let upload = (dims : Array[Int32], x : Array[Double]) => {
    b.from_values(dims, x, cuda_device=-1, requires_grad=false, dtype=Float32)
  }
  let model = GenModel::new(
    b,
    upload([29], Array::make(29, 0.3)),
    upload([29], Array::make(29, 0.0)),
    context_dim=33,
    device=-1,
    dt=0.02,
    decimation=4,
    world_hidden=[16, 16, 16],
    policy_hidden=[16, 12, 8],
    critic_hidden=[12, 8],
  )
  let id = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]
  let body : @aligned.BodySpec = {
    name: "pelvis",
    parent: -1,
    joint: -1,
    axis: [0, 0, 1],
    offset_p: [0, 0, 0],
    offset_rotation: id,
    pivot: [0, 0, 0],
    qref: 0.0,
  }
  let kin : @aligned.Kinematics = {
    bodies: [body],
    tracked: [0],
    q_lo: Array::make(29, -1.4),
    q_hi: Array::make(29, 1.4),
  }
  let learner = GenLearner::new(model, @geometry.Context::new(b, kin, -1))
  let frames = upload(
    [64, 71],
    Array::makei(64 * 71, i => {
      let t = (i / 71).to_double()
      match i % 71 {
        2 => 0.8
        3 => 1.0
        13 => t * 0.001
        42 => 0.05
        _ => 0.0
      }
    }),
  )
  let motions = GenMotions::new(b, frames)
  let ix = (vals : Array[Double]) => {
    b.from_values(
      [vals.length()],
      vals,
      cuda_device=-1,
      requires_grad=false,
      dtype=Int64,
    )
  }
  let time = ix([0, 1, 2, 3])
  let ends = ix([60, 60, 63, 63])
  let state = GenState::from_replay(b, frames.index_select(time))
  let goal = state.goals(b, motions.window(time, ends))
  assert_eq(goal.actor.shape(), [4, 640])
  assert_eq(goal.world.shape(), [4, 670])
  let action = model.act(state, goal)
  model.observe(state, action, goal)
  let ctx = upload([4, 33], Array::make(132, 0.0))
  let before_world = model.dynamics.layers[1].weight.values()
  let loss = learner.fit_world(
    frames.narrow(0, 0, 32).reshape([4, 8, 71]),
    upload([4, 8, 29], Array::make(4 * 8 * 29, 0.0)),
    ctx,
  )
  assert_true(@numeric.finite(loss) && loss > 0.0)
  assert_true(before_world != model.dynamics.layers[1].weight.values())
  let fixed_world = model.dynamics.layers[1].weight.values()
  let before_actor = model.decoder.layers[1].weight.values()
  let before_critic = model.critic.layers[1].weight.values()
  let (ret, value_loss) = learner.improve(
    motions,
    state,
    action.stop_gradient(),
    ctx,
    time,
    ends,
    ix(Array::makei(128, i => i.to_double())),
    height=0.25,
    tilt=0.8,
    horizon=32,
  )
  assert_true(@numeric.finite(ret) && @numeric.finite(value_loss))
  assert_true(before_actor != model.decoder.layers[1].weight.values())
  assert_true(before_critic != model.critic.layers[1].weight.values())
  assert_eq(fixed_world, model.dynamics.layers[1].weight.values())
  let dir = @env.get_env_var("TMPDIR").unwrap_or("/tmp") +
    "/moonrobo-gencoord-" +
    @env.now().to_string()
  learner.save_weights(dir, 1, 8)
  defer {
    for file in @fs.read_dir(dir) {
      @fs.remove_file(dir + "/" + file)
    }
    @fs.remove_dir(dir)
  }
  let before = model.act(state, goal).values()
  let loss2 = learner.fit_world(
    frames.narrow(0, 0, 32).reshape([4, 8, 71]),
    upload([4, 8, 29], Array::make(4 * 8 * 29, 0.0)),
    ctx,
  )
  let step2 = model.dynamics.layers[1].weight.values()
  assert_eq(learner.load_weights(dir), (1, 8))
  assert_eq(before, model.act(state, goal).values())
  let loss2b = learner.fit_world(
    frames.narrow(0, 0, 32).reshape([4, 8, 71]),
    upload([4, 8, 29], Array::make(4 * 8 * 29, 0.0)),
    ctx,
  )
  assert_eq(loss2, loss2b)
  assert_eq(step2, model.dynamics.layers[1].weight.values())
  let perm = ix(Array::makei(128, i => (127 - i).to_double()))
  let next_block = (block : Int32) => {
    learner.improve(
      motions,
      state,
      action.stop_gradient(),
      ctx,
      time,
      ends,
      perm,
      height=0.25,
      tilt=0.8,
      microbatch=block,
    )
  }
  ignore(learner.load_weights(dir))
  let (full_ret, full_loss) = next_block(4)
  let actor_weights = model.decoder.layers[1].weight.values()
  let critic_weights = model.critic.layers[1].weight.values()
  ignore(learner.load_weights(dir))
  let (split_ret, split_loss) = next_block(2)
  near([split_ret, split_loss], [full_ret, full_loss], 0.0001)
  near(model.decoder.layers[1].weight.values(), actor_weights, 0.0001)
  near(model.critic.layers[1].weight.values(), critic_weights, 0.0001)
}

///|
test "authors' reset distribution across falls, timeouts and clip ends" {
  let sampler = GenReset::new(5, 29, 2, 0.02)
  for t in 0..<40 {
    let fall = t % 11 == 5
    let end_ = t % 13 == 6
    let out = t % 17 == 8
    let flag = (x : Bool) => if x { 1.0 } else { 0.0 }
    let p = sampler.record([t % 29, (7 + t * 3) % 29], [
      0.02 * t.to_double(),
      flag(fall || out),
      flag(fall),
      0.0,
      flag(out),
      0.045,
      flag(end_),
      0.0,
      flag(end_),
      0.0,
    ])
    if t == 39 {
      assert_eq(sampler.count, [5, 8, 5, 6, 7])
      near(
        sampler.value,
        [6.08367729187, 7.1294260025, 7.7638401985, 9.438908577, 7.5644583702],
        0.00001,
      )
      near(
        p.unwrap(),
        [
          0.55907833576, 0.1265489161, 0.10539659858, 0.10008177906, 0.1088943556,
        ],
        0.000003,
      )
    } else if t != 19 {
      assert_true(p is None)
    }
  }
}

///|
test "valid replay windows match a chronological scan across wraps and terminations" {
  let done_ = Array::makei(70, i => i == 10 || i == 12 || i == 27 || i == 49)
  let w : ValidWindows = {
    slots: Array::make(11, 0),
    head: 0,
    count: 0,
    streak: 0,
  }
  for t, ended in done_ {
    w.insert(t, ended)
    let expected = []
    for j in (t - 10).max(0)..<(t - 6) {
      if !done_[j:j + 7].any(x => x) {
        expected.push(j)
      }
    }
    assert_eq(Array::makei(w.count, i => w.slots[(w.head + i) % 11]), expected)
  }
}

///|
/// CPU FP32 oracle from the authors' MultiEncoderAE, _assemble_goal and
/// Dynamics(GenCoordRepresentation) at revision 5f69628. Both sides receive
/// the same deterministic dense weights; there is no RNG or simulator here.
test "official actor plus world across 32 differentiable steps" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    return
  }
  let b = @tensor.Backend::open(path)
  let put = (shape : Array[Int32], values : Array[Double]) => {
    b.from_values(
      shape,
      values,
      cuda_device=-1,
      requires_grad=false,
      dtype=Float32,
    )
  }
  let model = GenModel::new(
    b,
    put([29], Array::make(29, 0.3)),
    put([29], Array::make(29, -0.04)),
    context_dim=3,
    device=-1,
    dt=0.02,
    decimation=4,
    world_hidden=[9, 8],
    policy_hidden=[10, 8],
  )
  let fill = (net : Mlp, seed : Int32) => {
    for i, l in net.layers {
      let assign = (p : @tensor.Tensor, k : Int32, base : Double) => {
        let shape = p.shape()
        let size = shape.fold(init=1, (m, d) => m * d)
        let values = Array::makei(size, j => {
          base + ((j + seed + i * 3 + k) % 23 - 11).to_double() * 0.017
        })
        p.copy_values_from(put(shape, values))
      }
      assign(l.weight, 1, 0.0)
      assign(l.bias, 2, 0.0)
      if l.norm_weight is Some(w) && l.norm_bias is Some(v) {
        assign(w, 3, 1.0)
        assign(v, 4, 0.0)
      }
    }
  }
  fill(model.dynamics, 3)
  fill(model.encoder, 7)
  fill(model.decoder, 11)
  let row = [
    0.1, -0.3, 0.7, 0.5, 0.5, -0.5, 0.5, 0.3, -0.9, 0.4, 0.2, 0.5, -0.3,
  ]
  row.append(Array::makei(29, i => i.to_double() / 49.0))
  row.append(Array::makei(29, i => i.to_double() / 83.0))
  let mut s = GenState::from_replay(b, put([1, 71], row))
  let ctx = put([1, 3], [0.15, -0.25, 0.35])
  let series = []
  let mut action = put([1, 29], Array::make(29, 0.0))
  for t in 0..<32 {
    let flat = []
    for i in preview_frames(t, 42) {
      let f = i.to_double()
      flat.append([
        0.1 + 0.001 * f,
        -0.3 + 0.005 * f,
        0.7 + 0.002 * f,
        0.7,
        0.5,
        -0.5,
        0.1,
      ])
      flat.append(Array::make(6, 0.0))
      flat.append(
        Array::makei(58, j => {
          if j < 29 {
            (j + 2 * i).to_double() * 0.001
          } else {
            (j - i).to_double() * 0.002
          }
        }),
      )
    }
    action = model.act(s, s.goals(b, put([1, 10, 71], flat)))
    s = model.step(s, action, ctx, frozen=true)
    if t == 0 || t == 7 || t == 31 {
      let a = action.values()
      series.append([
        a[0],
        a[17],
        s.position.values()[0],
        s.reduced.values()[67],
      ])
    }
  }
  near(
    series,
    [
      0.6792047024, 0.4486302137, 0.1035362929, 0.4384158552, 0.7109569311, 0.4469122291,
      0.0500937253, 1.3192994595, 0.6886491776, 0.4188876152, -0.9505277276, 4.4153451920,
    ],
    0.00002,
  )
  let score = s.reduced
    .square()
    .sum()
    .affine(0.1)
    .add(s.position.square().sum())
    .add(action.square().sum())
  near(score.values(), [201.66879272460938], 0.001)
  score.backward()
  let g = model.decoder.layers[0].weight.gradient().values()
  near(
    [0, 42, 173, 247, 546].map(i => g[i]),
    [0.0021766741, 0.0626034737, -0.0968199968, -0.0325201973, 0.0037899581],
    0.00001,
  )
}

///|
/// The layout comes from the live asset. The expected values were generated by
/// mjlab_research ForwardKinematics(float64) and SuperMimic tracking_reward.
test "official G1 kinematics, reward and joint gradients" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) &&
    @env.get_env_var("MOONROBO_GENCOORD_LAYOUT") is Some(layout) else {
    return
  }
  let b = @tensor.Backend::open(path)
  guard @json.parse(@fs.read_file_to_string(layout)) is Object(fields) else {
    fail("invalid layout")
  }
  let kin : @aligned.Kinematics = @json.from_json(fields["geometry"])
  let cfg = { ..@aligned.RewardConfig::default(), soft_limit_factor: 1.0, }
  let geometry = @geometry.Context::new(
      b,
      kin,
      -1,
      reward_cfg=cfg,
      dtype=Float64,
      body_orientation_batched=true,
    )
    .with_heading_mode(GenCoordYaw)
    .with_rotation_error_mode(GenCoordTraceAcos)
  let put = (x : Array[Double], grad : Bool) => {
    b.from_values(
      [1, x.length()],
      x,
      cuda_device=-1,
      requires_grad=grad,
      dtype=Float64,
    )
  }
  let q = (f : (Int32) -> Double) => Array::makei(29, f)
  let s : @geometry.State = {
    p: put([0.12, -0.17, 0.76], true),
    rotation: @geometry.quat_to_mat(b, put([0.7, 0.5, -0.5, 0.1], false)),
    v: put([0.3, -0.7, 0.9], false),
    w: put([0.1, 0.3, -0.5], false),
    q: put(q(j => (j - 13).to_double() * 0.039), true),
    qd: put(q(j => (j * 3 % 17 - 8).to_double() * 0.08), false),
  }
  let r : @geometry.State = {
    p: put([0.15, -0.12, 0.79], false),
    rotation: @geometry.quat_to_mat(b, put([0.5, 0.5, -0.5, 0.5], false)),
    v: put([0.2, -0.55, 0.75], false),
    w: put([0.16, 0.2, -0.46], false),
    q: put(q(j => (j - 9).to_double() * 0.031), false),
    qd: put(q(j => (j * 2 % 19 - 9).to_double() * 0.07), false),
  }
  let body = geometry.forward(s)[10]
  let pose = body.p.values()
  pose.append(body.v.values())
  pose.append(body.w.values())
  pose.append(body.rotation.values()[0:3].to_owned())
  near(
    pose,
    [
      0.0510950879022, -0.161720936004, 1.02327672612, 0.483095148635, -0.757394333792,
      0.937892426476, 0.795042001674, 0.815498286244, -0.36993792916, 0.269636358856,
      -0.962456469633, -0.0312054169051,
    ],
    1.0e-8,
  )
  let value = geometry.reward(
    s,
    r,
    put(q(j => j.to_double() * 0.03 - 0.5), false),
    put(q(j => j.to_double() * 0.02 - 0.25), false),
  )
  near(value.values(), [0.0234671322473785], 1.0e-9)
  value.backward()
  let g = s.q.gradient().values()
  near(
    [0, 4, 12, 15, 18, 21, 23, 25].map(j => g[j]),
    [
      0.004857757498, 0.000211951927, 0.003432981582, 0.002133066523, 0.000479210872,
      0.000071703184, 0.000379215346, 0.000134254929,
    ],
    1.0e-9,
  )
  near(
    s.p.gradient().values(),
    [0.006355637454, 0.010592729090, 0.012862333925],
    1.0e-9,
  )
}

///|
test "device reset follows authors' FP32 values and FP64 accumulated effort" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    return
  }
  let b = @tensor.Backend::open(path)
  let like = b.from_values(
    [1],
    [0.0],
    cuda_device=-1,
    requires_grad=false,
    dtype=Float32,
  )
  let sampler = DeviceReset::new(like, 5, 29, 2, 0.02)
  for t in 0..<40 {
    let fall = t % 11 == 5
    let end_ = t % 13 == 6
    let timeout = t % 17 == 8
    let flag = (x : Bool) => if x { 1.0 } else { 0.0 }
    let row = [
      0.02 * t.to_double(),
      flag(fall || timeout),
      flag(fall),
      0.0,
      flag(timeout),
      0.045,
      flag(end_),
      0.0,
      flag(end_),
      0.0,
    ]
    let out = sampler.record(
      [t % 29, (7 + t * 3) % 29],
      row,
      b.from_values(
        [2, 5],
        row,
        cuda_device=-1,
        requires_grad=false,
        dtype=Float32,
      ),
    )
    if t == 19 {
      near(
        sampler.value.values(),
        [
          4.930192470550537, 7.786556243896484, 7.749327182769775, 9.99216365814209,
          9.749910354614258,
        ],
        0.0,
      )
      near(
        out.unwrap().values(),
        [
          0.5993328094482422, 0.10031634569168091, 0.10034721344709396, 0.1000012755393982,
          0.10000233352184296,
        ],
        0.00000006,
      )
    } else if t == 39 {
      near(
        sampler.value.values(),
        [
          6.083677291870117, 7.129426002502441, 7.763840198516846, 9.438908576965332,
          7.56445837020874,
        ],
        0.0,
      )
      near(
        out.unwrap().values(),
        [
          0.5590783357620239, 0.1265489161014557, 0.10539659857749939, 0.10008177906274796,
          0.10889435559511185,
        ],
        0.00000006,
      )
    } else {
      assert_true(out is None)
    }
  }
}
