///|
/// Parent-directory test_aligned_data.py CPU motion fixtures.
fn data_test_clips() -> Array[MotionClip] {
  Array::makei(2, c => {
    name: "fixture-" + c.to_string(),
    sha256: "fixture",
    rows: Array::makei(if c == 0 { 31 } else { 61 }, i => {
      let row = Array::make(36, 0.0)
      row[0] = i.to_double() / 30.0
      row[6] = 1.0
      row
    }),
  })
}

///|
test "a 50 Hz benchmark retains the final frame at a roundoff-sensitive duration" {
  let rows = Array::makei(233, i => {
    let row = Array::make(36, 0.0)
    row[0] = i.to_double()
    row[6] = 1
    row
  })
  let motion = MotionLibrary::new(
    [{ name: "endpoint", sha256: "fixture", rows, }],
    fixture_kin(),
    source_fps=50,
    exact_control_frames=true,
    compute_body_features=false,
  )
  assert_eq(motion.clip_end[0], 232)
  assert_eq(motion.states[motion.clip_end[0]].p[0], 232.0)
}

///|
test "parent data resampling velocity goals terminal bins and full horizon resets" {
  let motion = MotionLibrary::new(data_test_clips(), fixture_kin())
  assert_eq(
    Array::makei(2, i => motion.clip_end[i] - motion.clip_start[i] + 1),
    [51, 101],
  )
  assert_eq(motion.bins.length(), 3)
  assert_eq(motion.clip_end.map(f => motion.frame_bin[f]), [0, 2])
  assert_true(motion.states.all(s => (s.v[0] - 1.0).abs() < 1.0e-10))
  for f in [0, 50, 151] {
    assert_eq(motion.goal(f, 10).length(), 730)
  }
  assert_eq([0, 50, 151].map(f => motion.future_frames(f, 2)), [
    [1, 2],
    [50, 50],
    [151, 151],
  ])
  let sampler = ReturnBinSampler::new(motion.bins)
  let rng = @numeric.Rng::new(12U)
  assert_true(
    sampler
    .sample(4000, () => rng.uniform())
    .all(pair => pair.0 < motion.clip_end[motion.clip_id[pair.0]]),
  )
  assert_true(
    sampler
    .sample(400, () => rng.uniform(), min_remaining_steps=32)
    .all(pair => pair.0 + 32 <= motion.clip_end[motion.clip_id[pair.0]]),
  )
  // Terminal-only upstream bins are deliberately excluded.
  assert_eq(motion.bins.filter(b => b.clip_end == 50).map(b => b.start), [0])
}

///|
test "parent data duplicate bin completions commute and checkpoint draw stream is exact" {
  let motion = MotionLibrary::new(data_test_clips(), fixture_kin())
  let first = ReturnBinSampler::new(motion.bins)
  let second = ReturnBinSampler::new(motion.bins)
  let episodes : Array[CompletedEpisode] = [
    { bin: 0, discounted_return: 2.0, bootstrap: None, },
    { bin: 0, discounted_return: 6.0, bootstrap: None, },
    { bin: 2, discounted_return: 10.0, bootstrap: None, },
  ]
  first.update(episodes)
  second.update([episodes[2], episodes[0], episodes[1]])
  assert_eq(first.snapshot().0, [0.8, 0.0, 2.0])
  assert_eq(first.snapshot().0, second.snapshot().0)
  assert_eq(first.snapshot().2, [2, 0, 1])
  assert_true(first.probabilities()[1] > first.probabilities()[2])
  let rng = @numeric.Rng::new(12U)
  ignore(first.sample(15, () => rng.uniform()))
  let (g, average, count) = first.snapshot()
  second.restore(g, average, count)
  let copied = rng.snapshot()
  assert_eq(
    first.sample(100, () => rng.uniform()),
    second.sample(100, () => copied.uniform()),
  )
  let sampler = ReturnBinSampler::new(motion.bins, gamma=0.5)
  sampler.update([
    { bin: 0, discounted_return: 0.15, bootstrap: Some((2, 0.2, false)), },
    { bin: 1, discounted_return: 0.15, bootstrap: Some((2, 0.2, true)), },
  ])
  for i, value in [0.04, 0.03, 0.0] {
    assert_true((sampler.snapshot().0[i] - value).abs() < 1.0e-12)
  }
}

///|
test "parent SMC reset mixture equation and unique completed-return update contract" {
  let motion = MotionLibrary::new(data_test_clips(), fixture_kin())
  let sampler = ReturnBinSampler::new(motion.bins)
  sampler.restore([0.0, 5.0, 10.0], Array::make(3, 1.0 / 3.0), [0, 0, 0])
  let soft = [1.0, @math.exp(-12.5), @math.exp(-25.0)]
  let total = soft.fold(init=0.0, (a, b) => a + b)
  let probabilities = sampler.probabilities()
  for i in 0..<3 {
    assert_true(
      (probabilities[i] - (0.6 / 3.0 + 0.4 * soft[i] / total)).abs() < 1.0e-12,
    )
  }
  sampler.update([
    { bin: 0, discounted_return: 3.0, bootstrap: None, },
    { bin: 2, discounted_return: 5.0, bootstrap: None, },
  ])
  for i, value in [0.6, 5.0, 9.0] {
    assert_true((sampler.snapshot().0[i] - value).abs() < 1.0e-12)
  }
}

///|
async test "parent data manifest identity verifies source SHA and rejects tampering" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="moonrobo-aligned-motion-")
    group.add_defer(() => @fs.rmdir(dir, recursive=true))
    let clip = data_test_clips()[0]
    let csv = clip.rows
      .map(row => row.map(x => x.to_string()).join(","))
      .join("\n") +
      "\n"
    @fs.write_file(
      dir + "/fixture.csv",
      @utf8.encode(csv),
      create_mode=CreateOrTruncate,
    )
    let manifest : MotionCatalog = {
      format: "moonrobo.aligned-motion-catalog.v1",
      quaternion_order: "xyzw",
      source_fps: 30.0,
      clips: [
        {
          id: "dance",
          path: "fixture.csv",
          sha256: @artifacts.sha256(@utf8.encode(csv)),
          layout: "root_xyz+quaternion_xyzw+g1_29_joint_angles",
          fps: None,
        },
      ],
      splits: { "train": ["dance"], "evaluation": ["dance"] },
    }
    @fs.write_file(
      dir + "/manifest.json",
      @utf8.encode(manifest.to_json().stringify()),
      create_mode=CreateOrTruncate,
    )
    let loaded = load_motion_manifest(
      dir + "/manifest.json",
      fixture_kin(),
      split="evaluation",
    )
    assert_eq(loaded.motion.names, ["dance"])
    assert_eq(loaded.split, "evaluation")
    @fs.write_file(
      dir + "/fixture.csv",
      @utf8.encode(csv + "\n"),
      create_mode=CreateOrTruncate,
    )
    assert_true(
      (Ok(load_motion_manifest(dir + "/manifest.json", fixture_kin())) catch {
        e => Err(e)
      })
      is Err(_),
    )
  }
}

///|
test "parent data reference-only loading skips FK and preserves every goal feature" {
  let full = MotionLibrary::new(data_test_clips(), fixture_kin())
  let no_fk : Kinematics = { bodies: [], tracked: [999], q_lo: [], q_hi: [], }
  let light = MotionLibrary::new(
    data_test_clips(),
    no_fk,
    compute_body_features=false,
  )
  assert_true(light.bodies.is_empty())
  for f in [0, 50, 151] {
    assert_eq(light.goal(f, 10), full.goal(f, 10))
  }
}

///|
test "parent MDP observation modes resolve translation and heading with exact prefixes" {
  let s = fixture_state()
  let translated = { ..s, p: vec_add(s.p, [0.2, 0.0, 0.0]), }
  let rotated = { ..s, rotation: so3_exp([0.0, 0.0, @math.PI / 6.0]), }
  let prev = Array::make(29, 0.0)
  let xi = Array::make(33, 0.0)
  let smc = observation(s, prev, xi, s.q, s, Smc)
  for mode in [Paper, Smc, Observable] {
    let obs = observation(s, prev, xi, s.q, s, mode)
    assert_eq(obs.length(), mode.dim())
    assert_eq(
      obs[0:mode.dim().min(99)].to_owned(),
      smc[0:mode.dim().min(99)].to_owned(),
    )
    let shifted = observation(translated, prev, xi, s.q, s, mode)
    if mode == Observable {
      assert_eq(vec_sub(shifted[99:102].to_owned(), obs[99:102].to_owned()), [
        -0.2, 0.0, 0.0,
      ])
      assert_true(
        square_norm(vec_sub(observation(rotated, prev, xi, s.q, s, mode), obs)) >
        0.01,
      )
    } else {
      assert_eq(shifted, obs)
    }
  }
}

///|
test "parent MDP scaled default action and its pullback have no reference override" {
  let defaults = default_joint_positions()
  let scales = joint_names().map(name => motor_of(name).action_scale())
  assert_eq(action_to_setpoint(Array::make(29, 1.0)), vec_add(defaults, scales))
  let tape = @numeric.Tape::new()
  let action = tape.vector(Array::make(29, 1.0))
  let outputs = Array::makei(29, i => {
    tape.add(tape.scalar(defaults[i]), tape.scale(action[i], scales[i]))
  })
  let sum = tape.scale(tape.mean(outputs), 29.0)
  tape.backward(sum)
  for i, v in action {
    assert_true(
      (tape.gradient(v) - scales[i]).abs() < 1.0e-15 && scales[i] > 0.0,
    )
  }
}

///|
test "parent MDP reference-relative low sideways failure and survival derivatives" {
  let s = fixture_state()
  let low = {
    ..s,
    p: [0.0, 0.0, 0.12],
    rotation: so3_exp([@math.PI / 2.0, 0.0, 0.0]),
  }
  assert_true(!termination(low, low))
  assert_true(termination({ ..low, p: [0.0, 0.0, 0.38], }, low))
  let tape = @numeric.Tape::new()
  let lifted = lift(tape, { ..low, p: [0.0, 0.0, 0.36], })
  let survival = tape.sub(
    tape.scalar(1.0),
    ad_failure(tape, lifted, low, RewardConfig::default()),
  )
  tape.backward(survival)
  assert_true(
    finite(tape.gradient(lifted.p[2])) && tape.gradient(lifted.p[2]).abs() > 1.0,
  )
}

///|
test "parent MDP reward scales errors smoothness and joint limits" {
  let s = fixture_state()
  let kin = fixture_kin()
  let a = Array::make(29, 0.0)
  let reference = kin.forward(s)
  let perfect = reward(kin, s, s, reference, a, a)
  assert_true((perfect.reward - 0.1).abs() < 1.0e-12)
  assert_eq(perfect.body_ori, 0.0)
  assert_eq(perfect.root_ori, 0.0)
  let shifted = reward(
    kin,
    { ..s, p: vec_add(s.p, [0.2, 0.0, 0.0]), },
    s,
    reference,
    a,
    a,
  )
  assert_true(
    (shifted.reward - 0.02 * (4.5 + 0.5 * @math.exp(-0.04 / 0.09))).abs() <
    1.0e-12,
  )
  let fast = reward(
    kin,
    { ..s, v: [0.2, 0.2, 0.2], w: [0.1, 0.1, 0.1], },
    s,
    reference,
    a,
    a,
  )
  assert_true(
    fast.body_linvel > 0.0 &&
    fast.body_angvel > 0.0 &&
    fast.reward < perfect.reward,
  )
  let smooth = reward(kin, s, s, reference, Array::make(29, 1.0), a)
  assert_true(
    (perfect.reward - smooth.reward - 0.02 * 0.1 * 29.0).abs() < 1.0e-12,
  )
  let q = s.q.copy()
  q[0] = 1.9
  assert_true(
    (reward(kin, { ..s, q, }, s, reference, a, a).joint_limit - 0.1).abs() <
    1.0e-12,
  )
}

///|
test "parent MDP rotation zero tiny-angle derivative and vertical heading fixes" {
  let tape = @numeric.Tape::new()
  let angle = tape.scalar(0.00001)
  let rot = ad_axis(tape, [1.0, 0.0, 0.0], angle)
  let loss = ad_square(tape, ad_log(tape, rot))
  tape.backward(loss)
  assert_true((loss.value - 1.0e-10).abs() < 1.0e-16)
  assert_true((tape.gradient(angle) - 0.00002).abs() < 1.0e-10)
  assert_eq(yaw_mat([0.0, 0.0, 1.0, 0.0, 1.0, 0.0, -1.0, 0.0, 0.0]), identity())
  let zero = @numeric.Tape::new()
  let angles = zero.vector([0.0, 0.0, 0.0])
  let zloss = ad_square(zero, ad_log(zero, ad_exp(zero, angles)))
  zero.backward(zloss)
  assert_eq(zloss.value, 0.0)
  assert_true(angles.all(v => finite(zero.gradient(v))))
}

///|
async test "parent acquired catalog verifies all forty original sources and 264705 rows" {
  let folder = "target/learning/g1-aligned-data"
  let catalog = @artifacts.load_json(folder + "/motion-manifest.json")
  guard catalog is Object(fields) else {
    fail("acquired catalog must be object")
  }
  assert_eq(
    fields["source_revision"],
    "ce1572906efe6157840e8474d5a0d7aa87481e74".to_json(),
  )
  guard fields["splits"] is Object(splits) && fields["clips"] is Array(clips) else {
    fail("catalog fields")
  }
  assert_eq(splits["train"], splits["evaluation"])
  assert_eq(clips.length(), 40)
  let mut total = 0
  for clip in clips {
    guard clip is Object(row) else { fail("catalog clip") }
    let path : String = @json.from_json(row["path"])
    let sha : String = @json.from_json(row["sha256"])
    let count : Int32 = @json.from_json(row["source_frames"])
    let data = @fs.read_file(folder + "/" + path).binary()
    assert_eq(@artifacts.sha256(data), sha)
    let rows = parse_motion_csv(@utf8.decode(data))
    assert_eq(rows.length(), count)
    assert_true(rows.all(r => square_norm(r[3:7].to_owned()).sqrt() > 0.99))
    total += rows.length()
  }
  assert_eq(total, 264705)
}
