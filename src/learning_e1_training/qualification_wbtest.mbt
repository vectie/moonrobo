///|
test "G1 bind uses both named elbow joint addresses without rotating a source frame or E1 bind" {
  let zero : @aligned.State = {
    p: [0.0, 0.0, 0.0],
    rotation: @aligned.identity(),
    v: [0.0, 0.0, 0.0],
    w: [0.0, 0.0, 0.0],
    q: Array::make(29, 0.0),
    qd: Array::make(29, 0.0),
  }
  let bodies : Array[@aligned.BodySpec] = @aligned.tracked_body_names().map(name => {
    name,
    parent: -1,
    joint: if name == "left_elbow_link" {
      4
    } else if name == "right_elbow_link" {
      7
    } else {
      -1
    },
    axis: [0.0, 1.0, 0.0],
    offset_p: zero.p,
    offset_rotation: zero.rotation,
    pivot: zero.p,
    qref: 0.0,
  })
  let kin : @aligned.Kinematics = {
    bodies,
    tracked: Array::makei(14, i => i),
    q_lo: [],
    q_hi: [],
  }
  let result = source_bind_pose(kin, zero, false)
  assert_eq(
    result.q,
    Array::makei(29, i => if i == 4 || i == 7 { @math.PI / 2.0 } else { 0.0 }),
  )
  assert_eq(zero.q, Array::make(29, 0.0))
  assert_eq(source_bind_pose(kin, zero, true).q, zero.q)
  bodies[0] = { ..bodies[0], name: "base_link", }
  assert_eq(source_bind_pose(kin, zero, false).q, zero.q)
}

///|
async test "pinned horse step exports a calibrated reference within the E1 self-contact limit" {
  guard @env.get_env_var("MOONROBO_G1_SCENE") is Some(scene) &&
    @env.get_env_var("MOONROBO_E1_HORSE_STEP_CSV") is Some(csv) else {
    println(
      "SKIP licensed horse-step regression: set MOONROBO_G1_SCENE and MOONROBO_E1_HORSE_STEP_CSV",
    )
    return
  }
  guard @env.get_env_var("MOONROBO_MUJOCO_LIBRARY") is Some(library) &&
    @env.get_env_var("MOONROBO_E1_DATASET") is Some(dataset) else {
    fail("horse-step regression requires E1 scene and MuJoCo")
  }
  let output = @fs.tmpdir(prefix="e1-horse-step") + "/candidate"
  let report = retarget_file(dataset, library, scene, csv, 120.0, output)
  assert_eq(
    (json_field(report, "source_sha256") : String),
    "065f9666b1c32c77e0d165ca732ecbd70eafa069428257aff76cd51d9f2274d0",
  )
  let quality : Json = json_field(report, "quality")
  let screen : Json = json_field(quality, "screen")
  let arms : Json = json_field(quality, "arm_fidelity")
  assert_eq((json_field(screen, "frames") : Int32), 452)
  assert_true((json_field(screen, "accepted") : Bool))
  assert_true(
    (json_field(screen, "maximum_self_penetration_m") : Double) <=
    Self_penetration_limit_m,
  )
  // The published zero-bind forearm error on this clip exceeded 60 degrees.
  assert_true(
    (json_field(arms, "mean_world_forearm_error_deg") : Double) < 15.0,
  )
  assert_eq(
    hash_file(output + "/motion.json"),
    (json_field(report, "output_sha256") : String),
  )
}

///|
test "active windows require motion in the recording interval" {
  let idle = Array::makei(1200, _ => [0.0, 0.0])
  assert_true(moving_starts(idle, 2.0).is_empty())
  let walking = Array::makei(1200, f => [f.to_double() / 30.0, 0.0])
  assert_eq(moving_starts(walking, 0.3), [0, 300, 600, 900])
  assert_true(moving_starts(walking, 2.0).is_empty())
}

///|
test "temporal filtering preserves a constant orientation across quaternion sign flips" {
  let rows = Array::makei(17, f => {
    [
      0.2,
      0.3,
      0.4,
      0.0,
      0.0,
      0.0,
      if f % 2 == 0 {
        1.0
      } else {
        -1.0
      },
      if f == 8 {
        1.0
      } else {
        0.0
      },
    ]
  })
  let filtered = smooth_locomotion(rows)
  for row in filtered {
    assert_true((row[6].abs() - 1.0).abs() < 1.0e-12)
    assert_true((row[0] - 0.2).abs() < 1.0e-12)
  }
  assert_eq(filtered[8][7], 70.0 / 256.0)
  assert_eq(filtered[7][7], filtered[9][7])
}

///|
test "bounded IK reoptimizes free coordinates after a joint reaches its limit" {
  let x = bounded_ik([[2.0, 1.0], [1.0, 2.0]], [3.0, 0.0], [0.0, -10.0], [
    0.5, 10.0,
  ])
  assert_true((x[0] - 0.5).abs() < 1.0e-12)
  assert_true((x[1] + 0.25).abs() < 1.0e-12)
}

///|
test "qualified production batches preserve paper nominal data ratios" {
  let c = Config::training()
  let fresh = c.environments.to_double() / c.update_to_data
  assert_eq(fresh, 1280.0)
  assert_eq(
    c.learner.wm_batches.to_double() * c.learner.wm_batch.to_double() / fresh,
    2.0,
  )
  assert_eq(
    c.learner.policy_batch.to_double() * c.learner.horizon.to_double() / fresh,
    12.8,
  )
  assert_eq(c.options(14000).learning_rate_decay_iterations, 14000)
}

///|
async test "analytic task Jacobians match finite differences and floor distance uses actual geometry" {
  guard @env.get_env_var("MOONROBO_MUJOCO_LIBRARY") is Some(library) &&
    @env.get_env_var("MOONROBO_E1_DATASET") is Some(directory) else {
    fail("qualification regression requires real E1 model and MuJoCo")
  }
  let dataset = open_dataset(directory)
  let robot = dataset.robot
  let rt = @sim.Runtime::open(library, directory + "/scene.xml")
  let kin = @tracking.kinematics(
    rt,
    names=robot.joints,
    tracked_names=robot.tracked,
    root_name="base_link",
  )
  let s : @aligned.State = {
    p: [0.1, -0.2, 0.8],
    rotation: @aligned.axis_angle_to_mat([0.0, 0.0, 1.0], 0.37),
    v: [0.0, 0.0, 0.0],
    w: [0.0, 0.0, 0.0],
    q: robot.embed(robot.default_q),
    qd: Array::make(29, 0.0),
  }
  let (bodies, jp, jr) = task_jacobians(kin, s, robot.joints.length())
  let layout = @tracking.joint_layout(rt, names=robot.joints)
  set_pose(rt, layout, s)
  for b, spec in kin.tracked {
    let native_jac = rt.point_jacobian(
      bodies[b].p,
      id_of_body(rt, kin.bodies[spec].name),
    )
    for k in 0..<3 {
      for axis in 0..<3 {
        let world = Array::makei(3, l => {
          native_jac[k][3 + l] * s.rotation[axis * 3 + l]
        }).fold(init=0.0, (a, b) => a + b)
        assert_true(
          (world - jp[b][robot.joints.length() + 3 + axis][k]).abs() < 1.0e-8,
        )
      }
    }
  }
  for j in 0..<(robot.joints.length() + 6) {
    let q = s.q.copy()
    let p = s.p.copy()
    let dr = [0.0, 0.0, 0.0]
    if j < robot.joints.length() {
      q[j] += 1.0e-6
    } else if j < robot.joints.length() + 3 {
      p[j - robot.joints.length()] += 1.0e-6
    } else {
      dr[j - robot.joints.length() - 3] = 1.0e-6
    }
    let rotation = @aligned.mat_mul(@aligned.so3_exp(dr), s.rotation)
    let next = kin.forward({ ..s, q, p, rotation, })
    for b in 0..<bodies.length() {
      for k in 0..<3 {
        assert_true(
          ((next[b].p[k] - bodies[b].p[k]) / 1.0e-6 - jp[b][j][k]).abs() <
          1.0e-5,
        )
      }
      let rotation = @aligned.so3_log(
        @aligned.mat_mul(
          next[b].rotation,
          @aligned.transpose(bodies[b].rotation),
        ),
      )
      for k in 0..<3 {
        assert_true((rotation[k] / 1.0e-6 - jr[b][j][k]).abs() < 1.0e-5)
      }
    }
  }
  rt.configure_collision(true)
  set_pose(rt, layout, s)
  let foot = id_of_body(rt, "l_leg_ankle_roll_link")
  let height = rt.body_floor_distance(foot)
  let (center, size) = rt.body_box(foot)
  let actual = kin.forward(s)[3]
  let r = actual.rotation
  let support = -(r[6] * center[0] + r[7] * center[1] + r[8] * center[2]) +
    r[6].abs() * size[0] +
    r[7].abs() * size[1] +
    r[8].abs() * size[2]
  assert_true((actual.p[2] - support - height).abs() < 1.0e-8)
  set_pose(rt, layout, { ..s, p: [0.1, -0.2, 0.81], })
  assert_true((rt.body_floor_distance(foot) - height - 0.01).abs() < 1.0e-8)
  set_pose(rt, layout, { ..s, p: [0.1, -0.2, 0.60], })
  let contacts = rt
    .collision_contacts()
    .filter(c => {
      (c.body_a == 0 && c.body_b == foot) || (c.body_b == 0 && c.body_a == foot)
    })
  assert_true(!contacts.is_empty())
  for c in contacts {
    let jac = rt.point_jacobian(c.point, foot)
    let sign = if c.body_b == foot { 1.0 } else { -1.0 }
    let gradient = Array::makei(3, k => c.normal_a_to_b[k] * jac[k][2] * sign).fold(
      init=0.0,
      (a, b) => a + b,
    )
    assert_true((gradient - 1.0).abs() < 1.0e-8)
  }
  for j in 0..<robot.joints.length() {
    assert_true((rt.actuator_gain()[j] - robot.stiffness[j]).abs() < 1.0e-10)
    assert_true((rt.actuator_damping()[j] - robot.damping[j]).abs() < 1.0e-10)
    assert_true((rt.joint_armatures()[j] - robot.armature[j]).abs() < 1.0e-10)
  }
  let rows = Array::makei(80, f => {
    let q = s.q.copy()
    q[13] += 0.12 * @math.sin(f.to_double() * 0.03)
    let row = [0.0, 0.0, 0.8, 0.0, 0.0, 0.0, 1.0]
    row.append(q)
    row
  })
  let source = @aligned.MotionLibrary::new(
    [{ name: "moving", sha256: "fixture", rows, }],
    kin,
    source_fps=50.0,
  )
  let (fitted, quality) = fit_trajectory(source, kin, kin, robot)
  assert_eq(fitted.length(), 80)
  assert_true((json_field(quality, "body_rms_m") : Double) < 0.001)
  assert_true((fitted[60][20] - fitted[0][20]).abs() > 0.05)
}

///|
async test "qualified admission rejects missing evidence and tampered reports" {
  guard @env.get_env_var("MOONROBO_MUJOCO_LIBRARY") is Some(library) &&
    @env.get_env_var("MOONROBO_E1_DATASET") is Some(directory) else {
    fail("admission regression requires a qualified dataset")
  }
  let dataset = open_dataset(directory)
  let admission = require_admission(directory, dataset, library)
  let temporary = @fs.tmpdir(prefix="e1-admission")
  @fs.write_file(
    temporary + "/dataset.json",
    @fs.read_file(directory + "/dataset.json"),
    create_mode=CreateNew,
  )
  assert_true(
    (Some(require_admission(temporary, dataset, library)) catch { _ => None })
    is None,
  )
  @fs.write_file(
    temporary + "/admission.json",
    @utf8.encode(admission.stringify()),
    create_mode=CreateNew,
  )
  @fs.write_file(
    temporary + "/model-validation.json",
    @fs.read_file(directory + "/model-validation.json"),
    create_mode=CreateNew,
  )
  @fs.mkdir(temporary + "/reports")
  @fs.mkdir(temporary + "/motions")
  for entry in dataset.entries {
    @fs.write_file(
      temporary + "/" + entry.file,
      @fs.read_file(directory + "/" + entry.file),
      create_mode=CreateNew,
    )
  }
  let records : Array[Json] = json_field(admission, "accepted")
  for record in records {
    let file : String = json_field(record, "report")
    @fs.write_file(
      temporary + "/" + file,
      @fs.read_file(directory + "/" + file),
      create_mode=CreateNew,
    )
  }
  ignore(require_admission(temporary, dataset, library))
  let file : String = json_field(records[0], "report")
  @fs.write_file(temporary + "/" + file, b"{}", create_mode=CreateOrTruncate)
  assert_true(
    (Some(require_admission(temporary, dataset, library)) catch { _ => None })
    is None,
  )
  @fs.write_file(
    temporary + "/" + file,
    @fs.read_file(directory + "/" + file),
    create_mode=CreateOrTruncate,
  )
  @fs.write_file(
    temporary + "/" + dataset.entries[0].file,
    b"[]",
    create_mode=CreateOrTruncate,
  )
  assert_true(
    (Some(require_admission(temporary, dataset, library)) catch { _ => None })
    is None,
  )
}

///|
test "arm orientation ablations change only their own bilateral IK residuals" {
  for mode in [Original, Shoulders, Elbows, ShouldersAndElbows] {
    for stance in [true, false] {
      for b in 0..<14 {
        let want = match b {
          3 | 6 => if stance { 3.0 } else { 0.8 }
          7 => 0.25
          10 | 13 => 0.12
          8 | 11 if mode == Shoulders || mode == ShouldersAndElbows => 0.12
          9 | 12 if mode == Elbows || mode == ShouldersAndElbows => 0.12
          _ => 0.0
        }
        assert_eq(rotation_weight(b, stance, mode), want)
      }
    }
  }
}

///|
test "one arm fraction across frames preserves fixed coordinates and speed bounds" {
  let base = Array::make(10, 0.0)
  base[7] = 1.0
  let next = base.copy()
  next[7] = 0.9
  let a = blended_arm_q([0.0, 2.0, -3.0], base, [0], 0.25)
  let b = blended_arm_q([0.1, 2.0, -3.0], next, [0], 0.25)
  assert_eq(a, [0.75, 2.0, -3.0])
  assert_true((b[0] - 0.7).abs() < 1.0e-12)
  assert_true((b[0] - a[0]).abs() < 0.1)
}

///|
test "stance metrics use continuous support and the same sole material point" {
  let foot = FootStudy::new()
  let pose : SoleFrame = {
    p: [0.0, 0.0, 0.0],
    r: @aligned.identity(),
    gap: -0.001,
    stance: true,
  }
  let center = [0.0, 0.0, 0.0]
  let half = [0.1, 0.04, 0.02]
  foot.add(pose, None, center, half)
  foot.add({ ..pose, p: [0.03, 0.04, 0.0], }, Some(pose), center, half)
  foot.add({ ..pose, gap: 0.03, }, Some(pose), center, half)
  foot.add({ ..pose, stance: false, }, Some(pose), center, half)
  assert_eq(foot.samples, 3)
  assert_eq(foot.near, 2)
  assert_eq(foot.touching, 2)
  assert_eq(foot.lifted, 1)
  assert_eq(foot.slip_samples, 1)
  assert_true((foot.slip_distance_m - 0.05).abs() < 1.0e-12)
}
