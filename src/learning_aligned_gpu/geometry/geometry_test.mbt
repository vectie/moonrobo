///|
fn near(
  actual : Array[Double],
  expected : Array[Double],
  tolerance~ : Double = 1.0e-8,
) -> Unit raise {
  assert_eq(actual.length(), expected.length())
  for i in 0..<actual.length() {
    guard (actual[i] - expected[i]).abs() <= tolerance else {
      fail(
        "geometry mismatch at \{i}: actual \{actual[i]}, expected \{expected[i]}",
      )
    }
  }
}

///|
fn upload(
  backend : @tensor.Backend,
  rows : Array[Array[Double]],
  gradient~ : Bool = false,
  cuda_device~ : Int32 = -1,
) -> @tensor.Tensor raise {
  let values = []
  for row in rows {
    values.append(row)
  }
  backend.from_values(
    [rows.length(), rows[0].length()],
    values,
    cuda_device~,
    requires_grad=gradient,
    dtype=Float64,
  )
}

///|
test "SMC critic batched joins preserve generic-chain values and gradients" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP SMC critic geometry: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let backend = @tensor.Backend::open(path)
  let (kin, states, refs) = fixtures()
  let context = @geometry.Context::new(backend, kin, -1, dtype=Float64)
    .with_heading_mode(@geometry.SmcProjected)
    .with_smc_fk_layout(true)
    .with_native_cross(true)
  let a = upload(backend, states.map(@aligned.flatten_state), gradient=true)
  let b = upload(backend, states.map(@aligned.flatten_state), gradient=true)
  let reference = @geometry.State::from_flat71(
    backend,
    upload(backend, refs.map(@aligned.flatten_state)),
  )
  let xi = upload(backend, Array::make(3, Array::make(33, 0.01)))
  let left = context.critic_features(
    @geometry.State::from_flat71(backend, a),
    reference,
    xi,
  )
  let right = context
    .with_smc_critic_layout(true)
    .critic_features(@geometry.State::from_flat71(backend, b), reference, xi)
  near(left.values(), right.values(), tolerance=1.0e-10)
  left.square().sum().backward()
  right.square().sum().backward()
  near(a.gradient_values(), b.gradient_values(), tolerance=1.0e-9)
}

///|
test "cached reference FK preserves corrected critic tail values and state gradients" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP cached critic tail: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let backend = @tensor.Backend::open(path)
  let (kin, states, refs) = fixtures()
  let context = @geometry.Context::new(backend, kin, -1, dtype=Float64)
    .with_heading_mode(@geometry.OrthonormalAtlas)
    .with_smc_fk_layout(true)
    .with_smc_critic_layout(true)
    .with_native_cross(true)
  let a = upload(backend, states.map(@aligned.flatten_state), gradient=true)
  let b = upload(backend, states.map(@aligned.flatten_state), gradient=true)
  let reference = @geometry.State::from_flat71(
    backend,
    upload(backend, refs.map(@aligned.flatten_state)),
  )
  let xi = upload(backend, Array::make(3, Array::make(33, 0.01)))
  let cache = context.pack_reference_bodies(reference)
  let old = context.critic_features(
    @geometry.State::from_flat71(backend, a),
    reference,
    xi,
  )
  let reused = context.critic_features_cached_reference(
    @geometry.State::from_flat71(backend, b),
    reference,
    xi,
    cache,
  )
  near(old.values(), reused.values(), tolerance=1.0e-12)
  old.square().sum().backward()
  reused.square().sum().backward()
  near(a.gradient_values(), b.gradient_values(), tolerance=1.0e-11)
  assert_true(
    try {
      ignore(
        context.critic_features_cached_reference(
          @geometry.State::from_flat71(backend, b),
          reference,
          xi,
          cache.narrow(1, 0, 1),
        ),
      )
      false
    } catch {
      _ => true
    },
  )
}

///|
fn fixtures() -> (
  @aligned.Kinematics,
  Array[@aligned.State],
  Array[@aligned.State],
) {
  let bodies : Array[@aligned.BodySpec] = [
    {
      name: "root",
      parent: -1,
      joint: -1,
      axis: [0.0, 0.0, 1.0],
      offset_p: [0.0, 0.0, 0.0],
      offset_rotation: @aligned.identity(),
      pivot: [0.0, 0.0, 0.0],
      qref: 0.0,
    },
  ]
  for i in 0..<14 {
    bodies.push({
      name: "body\{i}",
      parent: if i < 2 {
        0
      } else {
        i - 1
      },
      joint: if i == 6 {
        -1
      } else {
        i
      },
      axis: if i % 3 == 0 {
        [1.0, 0.0, 0.0]
      } else if i % 3 == 1 {
        [0.0, 1.0, 0.0]
      } else {
        [0.0, 0.0, 1.0]
      },
      offset_p: [0.05, 0.02, -0.03],
      offset_rotation: @aligned.so3_exp([0.01, -0.03, 0.02]),
      pivot: [0.003, 0.005, 0.0],
      qref: 0.01,
    })
  }
  let kin : @aligned.Kinematics = {
    bodies,
    tracked: Array::makei(14, i => i + 1),
    q_lo: Array::make(29, -1.0),
    q_hi: Array::make(29, 1.0),
  }
  let states : Array[@aligned.State] = Array::makei(3, i => {
    p: [0.1 * i.to_double(), -0.2, 0.76 - 0.2 * i.to_double()],
    rotation: @aligned.so3_exp(
      if i == 0 {
        [0.0, 0.0, 0.0]
      } else if i == 1 {
        [0.1, 0.2, -0.5]
      } else {
        [0.0, 1.5707963267948966, 0.0]
      },
    ),
    v: [0.03, 0.2, -0.1],
    w: [0.1, -0.2, 0.03],
    q: Array::makei(29, j => (j - 14).to_double() * 0.08),
    qd: Array::makei(29, j => (j % 3).to_double() * 0.03),
  })
  let refs = states.map(s => {
    @aligned.world_integrate(
      s,
      Array::makei(70, i => {
        if i < 12 {
          0.02 * (i - 6).to_double()
        } else {
          0.01
        }
      }),
    )
  })
  (kin, states, refs)
}

///|
test "zero pivot FK specialization preserves mixed chains outputs and gradients" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP zero pivot FK integration")
    return
  }
  let backend = @tensor.Backend::open(path)
  let (kin, states, _) = fixtures()
  for i in 1..<kin.bodies.length() {
    let body = kin.bodies[i]
    // Includes zero and nonzero pivots, qrefs, fixed links and arbitrary axes.
    kin.bodies[i] = {
      ..body,
      pivot: if i % 2 == 0 {
        [0.0, 0.0, 0.0]
      } else {
        body.pivot
      },
      qref: if i % 3 == 0 {
        0.0
      } else {
        body.qref
      },
      axis: if i % 4 == 0 {
        [0.6, 0.8, 0.0]
      } else {
        body.axis
      },
    }
  }
  let values = []
  for state in states {
    values.append(@aligned.flatten_state(state))
  }
  for dtype in [@tensor.Float32, @tensor.Float64] {
    let context = @geometry.Context::new(backend, kin, -1, dtype~)
    let a = backend.from_values(
      [3, 71],
      values,
      cuda_device=-1,
      requires_grad=true,
      dtype~,
    )
    let b = backend.from_values(
      [3, 71],
      values,
      cuda_device=-1,
      requires_grad=true,
      dtype~,
    )
    let left = context.forward(
      @geometry.State::from_flat71(backend, a),
      all_bodies=true,
    )
    let right = context
      .with_zero_joint_pivot(true)
      .forward(@geometry.State::from_flat71(backend, b), all_bodies=true)
    let la = []
    let lb = []
    let check = (u : Array[Double], v : Array[Double]) => {
      assert_eq(u.length(), v.length())
      for i in 0..<u.length() {
        let bound = if dtype == @tensor.Float64 {
          1.0e-10
        } else {
          2.0e-6 + 2.0e-4 * v[i].abs()
        }
        assert_true((u[i] - v[i]).abs() <= bound)
      }
    }
    for i in 0..<left.length() {
      for
        (u, v) in [
          (left[i].p, right[i].p),
          (left[i].rotation, right[i].rotation),
          (left[i].v, right[i].v),
          (left[i].w, right[i].w),
        ] {
        check(u.values(), v.values())
        la.push(u.square().sum())
        lb.push(v.square().sum())
      }
    }
    backend.stack(la).sum().backward()
    backend.stack(lb).sum().backward()
    check(a.gradient_values(), b.gradient_values())
  }
}

///|
test "signed sparse FK axes and general-axis fallback preserve states and gradients" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP sparse FK integration")
    return
  }
  let backend = @tensor.Backend::open(path)
  let (kin, states, _) = fixtures()
  for i in 1..<kin.bodies.length() {
    let body = kin.bodies[i]
    if i % 4 == 0 {
      kin.bodies[i] = { ..body, axis: [0.6, 0.8, 0.0], }
    } else if i % 2 == 0 {
      kin.bodies[i] = { ..body, axis: body.axis.map(x => -x), }
    }
  }
  let context = @geometry.Context::new(backend, kin, -1, dtype=Float64)
  let raw = states.map(@aligned.flatten_state)
  let left = upload(backend, raw, gradient=true)
  let right = upload(backend, raw, gradient=true)
  let a = context.forward(
    @geometry.State::from_flat71(backend, left),
    all_bodies=true,
  )
  let b = context
    .with_sparse_joint_axis(true)
    .forward(@geometry.State::from_flat71(backend, right), all_bodies=true)
  let losses_a = []
  let losses_b = []
  for i in 0..<a.length() {
    for
      (u, v) in [
        (a[i].p, b[i].p),
        (a[i].rotation, b[i].rotation),
        (a[i].v, b[i].v),
        (a[i].w, b[i].w),
      ] {
      near(u.values(), v.values())
      losses_a.push(u.square().sum())
      losses_b.push(v.square().sum())
    }
  }
  backend.stack(losses_a).sum().backward()
  backend.stack(losses_b).sum().backward()
  near(left.gradient_values(), right.gradient_values())
}

///|
/// Run only when the LibTorch ABI 2 plugin was deliberately built by the caller.
test "batched geometry matches scalar WXYZ replay FK observations rewards and critic" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP geometry numerical integration: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let backend = @tensor.Backend::open(path)
  let (kin, states, refs) = fixtures()
  let context = @geometry.Context::new(backend, kin, -1, dtype=Float64)
  let raw = upload(backend, states.map(@aligned.flatten_state))
  let s = @geometry.State::from_flat71(backend, raw)
  let reference = @geometry.State::from_flat71(
    backend,
    upload(backend, refs.map(@aligned.flatten_state)),
  )
  near(s.flatten71(backend).values(), raw.values())
  near(
    @geometry.invariant_features(backend, s).values(),
    upload(backend, states.map(@aligned.invariant_features)).values(),
  )
  let xi_rows = Array::makei(3, i => {
    Array::makei(33, j => {
      if j == 0 {
        0.7 + i.to_double() * 0.03
      } else {
        j.to_double() * 0.0001
      }
    })
  })
  let xi = upload(backend, xi_rows)
  let xi_n = @geometry.normalize_xi(backend, xi)
  near(
    xi_n.values(),
    upload(backend, xi_rows.map(@aligned.normalize_xi)).values(),
  )
  let actions_rows = Array::makei(3, i => {
    Array::makei(29, j => (i + j).to_double() * 0.01)
  })
  let previous_rows = Array::makei(3, _ => Array::make(29, 0.01))
  let actions = upload(backend, actions_rows)
  let previous = upload(backend, previous_rows)
  assert_eq(@geometry.world_inputs(backend, s, actions, xi_n).shape(), [3, 133])
  let targets = @geometry.world_targets(backend, s, reference)
  near(
    targets.values(),
    upload(
      backend,
      Array::makei(3, i => @aligned.world_targets(states[i], refs[i])),
    ).values(),
  )
  let integrated = @geometry.world_integrate(backend, s, targets)
  near(
    integrated.flatten71(backend).values(),
    reference.flatten71(backend).values(),
  )
  near(@geometry.state_error(backend, reference, s).values(), targets.values())
  let body_tensors = context.forward(s, all_bodies=true)
  for i, body in body_tensors {
    let scalar = states.map(s => kin.forward(s, all_bodies=true)[i])
    near(body.p.values(), upload(backend, scalar.map(b => b.p)).values())
    near(
      body.rotation.reshape([3, 9]).values(),
      upload(backend, scalar.map(b => b.rotation)).values(),
    )
    near(body.v.values(), upload(backend, scalar.map(b => b.v)).values())
    near(body.w.values(), upload(backend, scalar.map(b => b.w)).values())
  }
  for mode in [@aligned.Paper, @aligned.Smc, @aligned.Observable] {
    let actual = context.observation(s, previous, xi, reference, mode)
    assert_eq(actual.shape(), [3, mode.dim()])
    near(
      actual.values(),
      upload(
        backend,
        Array::makei(3, i => {
          @aligned.observation(
            states[i],
            previous_rows[i],
            xi_rows[i],
            @aligned.default_joint_positions(),
            refs[i],
            mode,
          )
        }),
      ).values(),
    )
  }
  let reward = context.reward_terms(s, reference, actions, previous)
  let expected = Array::makei(3, i => {
    @aligned.reward(
      kin,
      states[i],
      refs[i],
      kin.forward(refs[i]),
      actions_rows[i],
      previous_rows[i],
    )
  })
  near(reward.reward.values(), expected.map(x => x.reward))
  near(reward.track.values(), expected.map(x => x.track))
  near(reward.body_pos.values(), expected.map(x => x.body_pos))
  near(reward.body_ori.values(), expected.map(x => x.body_ori))
  near(reward.body_linvel.values(), expected.map(x => x.body_linvel))
  near(reward.body_angvel.values(), expected.map(x => x.body_angvel))
  near(reward.root_pos.values(), expected.map(x => x.root_pos))
  near(reward.root_ori.values(), expected.map(x => x.root_ori))
  near(reward.action_rate.values(), expected.map(x => x.action_rate))
  near(reward.joint_limit.values(), expected.map(x => x.joint_limit))
  near(
    context.soft_failure(s, reference).values(),
    Array::makei(3, i => @aligned.soft_termination(states[i], refs[i])),
  )
  let critic = context.critic_features(s, reference, xi_n)
  assert_eq(critic.shape(), [3, 184])
  near(
    critic.values(),
    upload(
      backend,
      Array::makei(3, i => {
        @aligned.critic_features(
          kin,
          states[i],
          refs[i],
          kin.forward(refs[i]),
          @aligned.normalize_xi(xi_rows[i]),
        )
      }),
    ).values(),
  )
}

///|
test "batched rotation gradients finite at zero and pi and reward matches finite difference" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP geometry gradient integration: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let backend = @tensor.Backend::open(path)
  let vectors = [
    [0.0, 0.0, 0.0],
    [0.0, 3.141592653589793 - 1.0e-6, 0.0],
    [0.1, -0.2, 0.3],
  ]
  let input = upload(backend, vectors, gradient=true)
  let rotation = @geometry.so3_exp(backend, input)
  let log = @geometry.so3_log(backend, rotation)
  near(log.values(), upload(backend, vectors).values(), tolerance=2.0e-9)
  log.square().sum().backward()
  let gradient = input.gradient_values()
  near(
    gradient,
    upload(backend, vectors).affine(2.0).values(),
    tolerance=2.0e-5,
  )
  let (kin, states, refs) = fixtures()
  let context = @geometry.Context::new(backend, kin, -1, dtype=Float64)
  let raw = upload(backend, [@aligned.flatten_state(states[1])], gradient=true)
  let s = @geometry.State::from_flat71(backend, raw)
  let reference = @geometry.State::from_flat71(
    backend,
    upload(backend, [@aligned.flatten_state(refs[1])]),
  )
  let action = upload(backend, [Array::make(29, 0.0)])
  context.reward(s, reference, action, action).sum().backward()
  let actual = raw.gradient_values()
  for i in [0, 2, 4, 7, 10, 13, 20, 42] {
    let plus = @aligned.flatten_state(states[1])
    let minus = plus.copy()
    plus[i] += 1.0e-6
    minus[i] -= 1.0e-6
    let p = @aligned.reward(
        kin,
        @aligned.unflatten_state(plus),
        refs[1],
        kin.forward(refs[1]),
        Array::make(29, 0.0),
        Array::make(29, 0.0),
      ).reward
    let m = @aligned.reward(
        kin,
        @aligned.unflatten_state(minus),
        refs[1],
        kin.forward(refs[1]),
        Array::make(29, 0.0),
        Array::make(29, 0.0),
      ).reward
    near([actual[i]], [(p - m) / 2.0e-6], tolerance=2.0e-7)
  }
  // Exact reference tracking has a finite zero rotation gradient, with no floor.
  let ident = upload(
    backend,
    [@aligned.flatten_state(states[0])],
    gradient=true,
  )
  let ident_state = @geometry.State::from_flat71(backend, ident)
  context.reward(ident_state, ident_state, action, action).sum().backward()
  for value in ident.gradient_values() {
    assert_true(value == value && value.abs() < 1.0e100)
  }
}

///|
test "tracking reuse preserves reward tail gradients and detaches critic features" {
  let device = match @env.get_env_var("MOONROBO_OPTIMIZATION_TEST_DEVICE") {
    None | Some("cpu") => -1
    Some("cuda:0") => 0
    _ => fail("MOONROBO_OPTIMIZATION_TEST_DEVICE must be cpu or cuda:0")
  }
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    guard device < 0 else {
      fail("explicit CUDA geometry reuse test requires MOONROBO_TENSOR_LIBRARY")
    }
    println("SKIP geometry reuse integration: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let backend = @tensor.Backend::open(path)
  if device >= 0 {
    guard backend.cuda_device_count() > 0 &&
      backend.cuda_free_bytes(device) > 17179869184L else {
      fail(
        "CUDA geometry reuse parity requires a device and more than 16 GiB free",
      )
    }
  }
  let (kin, states, refs) = fixtures()
  let context = @geometry.Context::new(backend, kin, device, dtype=Float64)
  let baseline_raw = upload(
    backend,
    states.map(@aligned.flatten_state),
    gradient=true,
    cuda_device=device,
  )
  let cached_raw = upload(
    backend,
    states.map(@aligned.flatten_state),
    gradient=true,
    cuda_device=device,
  )
  let baseline = @geometry.State::from_flat71(backend, baseline_raw)
  let candidate = @geometry.State::from_flat71(backend, cached_raw)
  let reference_raw = upload(
    backend,
    refs.map(@aligned.flatten_state),
    cuda_device=device,
  )
  let reference = @geometry.State::from_flat71(backend, reference_raw)
  let action = upload(
    backend,
    Array::make(3, Array::make(29, 0.02)),
    cuda_device=device,
  )
  let previous = action.affine(0.5)
  let xi = upload(
    backend,
    Array::make(3, Array::make(33, 0.0)),
    cuda_device=device,
  )
  let cached = context.tracking_geometry(candidate, reference)
  let reward_a = context.reward(baseline, reference, action, previous)
  let reward_b = cached.reward(action, previous)
  near(reward_a.values(), reward_b.values())
  let baseline_tail = @geometry.State::from_flat71(
    backend,
    baseline_raw.narrow(0, 2, 1),
  )
  let reference_tail = @geometry.State::from_flat71(
    backend,
    reference_raw.narrow(0, 2, 1),
  )
  let tail_a = context.critic_features(
    baseline_tail,
    reference_tail,
    xi.narrow(0, 2, 1),
  )
  let tail_b = cached.narrow(2, 1).critic_features(xi.narrow(0, 2, 1))
  near(tail_a.values(), tail_b.values())
  reward_a.sum().add(tail_a.square().mean().affine(0.1)).backward()
  reward_b.sum().add(tail_b.square().mean().affine(0.1)).backward()
  near(
    baseline_raw.gradient_values(),
    cached_raw.gradient_values(),
    tolerance=1.0e-10,
  )
  // A detached cache must remain usable after backward, and never create a
  // second backward edge into the actor whose graph has already been consumed.
  let features = cached.detached().critic_features(xi)
  near(
    features.values(),
    context
    .critic_features(
      @geometry.State::from_flat71(backend, baseline_raw.stop_gradient()),
      reference,
      xi,
    )
    .values(),
  )
  try features.sum().backward() catch {
    @tensor.TensorError::Native(message) =>
      assert_true(message.contains("does not require grad"))
  } noraise {
    _ => fail("detached geometry retained an actor gradient edge")
  }
  let oversized = @geometry.Context::new(
    backend,
    { ..kin, tracked: Array::make(65, 0), },
    device,
    dtype=Float64,
  )
  try oversized.tracking_geometry(candidate, reference) catch {
    _ => ()
  } noraise {
    _ => fail("optional tracking cache exceeded its admitted body count")
  }
}
