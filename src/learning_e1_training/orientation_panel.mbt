///|
fn recorded_value(data : Bytes, i : Int32) -> Double {
  let p = 4 * i
  let bits = data[p].to_int() |
    (data[p + 1].to_int() << 8) |
    (data[p + 2].to_int() << 16) |
    (data[p + 3].to_int() << 24)
  Float::reinterpret_from_int(bits).to_double()
}

///|
fn recorded_state(
  data : Bytes,
  frame : Int32,
  joints : Int32,
) -> @aligned.State {
  let off = frame * (joints + 7)
  state_of_row(
    Array::makei(36, j => {
      if j < joints + 7 {
        recorded_value(data, off + j)
      } else {
        0.0
      }
    }),
  )
}

///|
fn audit_reward(angles : Array[Double]) -> Double {
  let cfg = @aligned.RewardConfig::default()
  let mse = angles.fold(init=0.0, (sum, x) => sum + x * x) /
    angles.length().to_double()
  @aligned.control_dt * @math.exp(-mse / (cfg.body_ori_std * cfg.body_ori_std))
}

///|
/// Compare rotations in the heading convention of the physical body-orientation reward.
/// Each side uses the root of the same pose as its body frames.
fn audit_angles(
  refs : Array[Array[Double]],
  poses : Array[Array[Double]],
) -> Array[Double] {
  let yaw = @aligned.yaw_mat(
    @aligned.mat_mul(poses[0], @aligned.transpose(refs[0])),
  )
  Array::makei(refs.length(), i => {
    angle(@aligned.mat_mul(yaw, refs[i]), poses[i])
  })
}

///|
fn body_rotations(
  kin : @aligned.Kinematics,
  s : @aligned.State,
) -> Array[Array[Double]] {
  kin.forward(s).map(b => b.rotation)
}

///|
fn calibrated_rotations(
  frames : Array[Array[Double]],
  offsets : Array[Array[Double]],
) -> Array[Array[Double]] {
  Array::makei(frames.length(), b => @aligned.mat_mul(frames[b], offsets[b]))
}

///|
/// Rebuild only the pinned kinematic reference. Actual poses and the original
/// orientation reward come directly from the previously recorded physical trials.
pub async fn orientation_panel(
  dataset : String,
  library : String,
  scene : String,
  csv : String,
  panel_path : String,
  recorded : String,
  output : String,
) -> Json {
  guard !@fs.exists(output) else {
    fail("orientation export needs a fresh directory")
  }
  let model = open_dataset(dataset)
  let rt = @sim.Runtime::open(library, dataset + "/scene.xml")
  let gs = @sim.Runtime::open(library, scene)
  let ek = @tracking.kinematics(
    rt,
    names=model.robot.joints,
    tracked_names=model.robot.tracked,
    root_name="base_link",
  )
  let gk = @tracking.kinematics(gs)
  let panel = @json.parse(@utf8.decode(read_bounded(panel_path, 1048576L)))
  let pins : Array[PanelClip] = json_field(panel, "clips")
  let refs = @json.parse(
    @utf8.decode(read_bounded(recorded + "/references.json", 4194304L)),
  )
  let hashes : Array[Json] = json_field(refs, "clips")
  assert_eq((json_field(refs, "panel_sha256") : String), hash_file(panel_path))
  assert_eq((json_field(refs, "g1_scene_sha256") : String), hash_file(scene))
  assert_eq(
    (json_field(refs, "target_scene_sha256") : String),
    hash_file(dataset + "/scene.xml"),
  )
  assert_eq(hashes.length(), pins.length())
  assert_eq(pins.length(), 40)
  let zero = state_of_row(
    [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0] + Array::make(29, 0.0),
  )
  let src_bind = body_rotations(gk, source_bind_pose(gk, zero, false))
  let dst_bind = body_rotations(ek, zero)
  let offsets = Array::makei(14, b => {
    @aligned.mat_mul(@aligned.transpose(src_bind[b]), dst_bind[b])
  })
  for b in 0..<14 {
    guard angle(@aligned.mat_mul(src_bind[b], offsets[b]), dst_bind[b]) < 1.0e-6 else {
      fail("anatomical bind correspondence differs")
    }
  }
  let rows : Array[Json] = []
  @fs.mkdir(output, recursive=true)
  for i, pin in pins {
    guard pin.catalog_index == i &&
      !pin.id.contains("..") &&
      !pin.id.has_prefix("/") &&
      pin.expected_steps > 0 &&
      pin.expected_steps <= 10000 else {
      fail("invalid panel entry")
    }
    let data = read_bounded(csv + "/" + pin.id + ".csv", 67108864L)
    assert_eq(@artifacts.sha256(data), pin.sha256)
    let clip : @aligned.MotionClip = {
      name: pin.id,
      sha256: pin.sha256,
      rows: @aligned.parse_motion_csv(@utf8.decode(data)),
    }
    let source = @aligned.MotionLibrary::new(
      [clip],
      gk,
      source_fps=(json_field(panel, "source_fps") : Double),
      compute_body_features=false,
    )
    let (fitted, _, _, _) = fit_screened_reference(
      source,
      clip,
      gk,
      rt,
      ek,
      model.robot,
      smooth=false,
      exact_control_frames=true,
    )
    let target_hash = @artifacts.sha256(@utf8.encode(Json(fitted).stringify()))
    assert_eq(pin.id, (json_field(hashes[i], "id") : String))
    assert_eq(target_hash, (json_field(hashes[i], "reference_sha256") : String))
    let target = @aligned.MotionLibrary::new(
      [{ ..clip, rows: fitted, sha256: target_hash, }],
      ek,
      source_fps=50.0,
      exact_control_frames=true,
      compute_body_features=false,
    )
    let prefix = i.to_string()
    let g = read_bounded(recorded + "/g1/" + prefix + ".f32", 2097152L)
    let e = read_bounded(recorded + "/e1/" + prefix + ".f32", 2097152L)
    let gm = read_bounded(recorded + "/g1/" + prefix + ".metrics.f32", 1048576L)
    let em = read_bounded(recorded + "/e1/" + prefix + ".metrics.f32", 1048576L)
    let common = (g.length() / 144 - 1).min(e.length() / 120 - 1)
    assert_eq(g.length(), (gm.length() / 44 + 1) * 144)
    assert_eq(e.length(), (em.length() / 44 + 1) * 120)
    guard common > 0 &&
      common <= pin.expected_steps &&
      fitted.length() == pin.expected_steps + 1 else {
      fail("frame range differs")
    }
    let buffer = @buffer.Buffer()
    let mut max_delta = 0.0
    for f in 0..<=common {
      let s = calibrated_rotations(
        body_rotations(gk, source.states[f]),
        offsets,
      )
      let t = body_rotations(ek, target.states[f])
      let a = body_rotations(ek, recorded_state(e, f, 23))
      let ga = calibrated_rotations(
        body_rotations(gk, recorded_state(g, f, 29)),
        offsets,
      )
      if f > 0 {
        let eg = audit_reward(audit_angles(s, ga))
        let ee = audit_reward(audit_angles(t, a))
        let delta = (eg - recorded_value(gm, (f - 1) * 11 + 4))
          .abs()
          .max((ee - recorded_value(em, (f - 1) * 11 + 4)).abs())
        max_delta = max_delta.max(delta)
        guard delta < 1.0e-7 else {
          fail(
            "per-step orientation reward differs: " +
            pin.id +
            " frame " +
            f.to_string(),
          )
        }
      }
      for group in [s, t, a, ga] {
        for rotation in group {
          for x in @aligned.mat_to_quat(rotation) {
            buffer.write_float_le(Float::from_double(x))
          }
        }
      }
    }
    let raw = buffer.to_bytes()
    assert_eq(raw.length(), (common + 1) * 4 * 14 * 4 * 4)
    @fs.write_file(output + "/" + prefix + ".f32", raw, create_mode=CreateNew)
    rows.push({
      "id": Json(pin.id),
      "steps": Json(common),
      "expected_steps": Json(pin.expected_steps),
      "reference_sha256": Json(target_hash),
      "g1_pose_sha256": Json(@artifacts.sha256(g)),
      "e1_pose_sha256": Json(@artifacts.sha256(e)),
      "sha256": Json(@artifacts.sha256(raw)),
      "reward_max_abs_error": Json(max_delta),
    })
  }
  let result : Json = {
    "format": "moonrobo.orientation-panel.v1",
    "panel_sha256": Json(hash_file(panel_path)),
    "generator_sha256": Json(hash_file("/proc/self/exe")),
    "e1_bodies": Json(model.robot.tracked),
    "g1_bodies": Json(@aligned.tracked_body_names()),
    "order": ["source", "e1_reference", "e1_physical", "g1_physical"],
    "quaternion": "wxyz, world rotations; both G1 streams calibrated into anatomical E1 bind axes",
    "clips": Json(rows),
  }
  @fs.write_file(
    output + "/manifest.json",
    @utf8.encode(result.stringify(indent=2)),
    create_mode=CreateNew,
  )
  result
}

///|
/// Score every physical counterfactual against the *same* calibrated source.
/// This independent reconstruction reads MuJoCo data.xmat, including for the
/// current policy where every physical body is checked against the geometry export.
pub async fn orientation_controls(
  dataset : String,
  library : String,
  geometry : String,
  recorded : String,
  cases : String,
  controls_path : String,
  output : String,
) -> Json {
  let profile = open_dataset(dataset)
  let rt = @sim.Runtime::open(library, dataset + "/scene.xml")
  let layout = @tracking.joint_layout(rt, names=profile.robot.joints)
  let ids = profile.robot.tracked.map(name => id_of_body(rt, name))
  let prior = @json.parse(@utf8.decode(read_bounded(controls_path, 1048576L)))
  let geo = @json.parse(
    @utf8.decode(read_bounded(geometry + "/manifest.json", 1048576L)),
  )
  let rows : Array[Json] = json_field(prior, "clips")
  let clips : Array[Json] = json_field(geo, "clips")
  let runs : Array[Json] = json_field(prior, "runs")
  let paths = [
    cases + "/p7bind0/rollouts",
    cases + "/p7/rollouts",
    cases + "/bind0/rollouts",
    recorded,
  ]
  assert_eq(
    (json_field(prior, "panel_sha256") : String),
    (json_field(geo, "panel_sha256") : String),
  )
  assert_eq(rows.length(), 40)
  assert_eq(runs.length(), 4)
  for j, path in paths {
    assert_eq(
      hash_file(path + "/final.json"),
      (json_field(runs[j], "report_sha256") : String),
    )
  }
  fn group(
    raw : Bytes,
    frame : Int32,
    channel : Int32,
  ) -> Array[Array[Double]] {
    Array::makei(14, b => {
      @aligned.quat_to_mat(
        Array::makei(4, k => {
          recorded_value(raw, ((frame * 4 + channel) * 14 + b) * 4 + k)
        }),
      )
    })
  }
  let mut max_angle = 0.0
  let results : Array[Json] = []
  for i, r in rows {
    let id : String = json_field(r, "id")
    assert_eq(id, (json_field(clips[i], "id") : String))
    let n : Int32 = json_field(r, "common")
    let expected : Int32 = json_field(clips[i], "expected_steps")
    let durations : Array[Int32] = json_field(r, "steps")
    let raw = read_bounded(geometry + "/" + i.to_string() + ".f32", 16777216L)
    assert_eq(@artifacts.sha256(raw), (json_field(clips[i], "sha256") : String))
    let poses : Array[Bytes] = []
    for path in paths {
      poses.push(read_bounded(path + "/e1/" + i.to_string() + ".f32", 2097152L))
    }
    let hashes = poses.map(bytes => @artifacts.sha256(bytes))
    assert_eq(hashes[3], (json_field(clips[i], "e1_pose_sha256") : String))
    for j, p in poses {
      assert_eq(p.length(), (durations[j] + 1) * 120)
    }
    let scores = Array::make(4, 0.0)
    for f in 0..<=n {
      let source = group(raw, f, 0)
      for j, p in poses {
        set_pose(rt, layout, recorded_state(p, f, 23))
        let all = rt.body_rotations()
        let actual = ids.map(index => all[index])
        if j == 3 {
          let native = group(raw, f, 2)
          for b in 0..<14 {
            max_angle = max_angle.max(angle(native[b], actual[b]))
          }
        }
        if f > 0 {
          scores[j] += audit_reward(audit_angles(source, actual)) /
            (0.1 * expected.to_double())
        }
      }
    }
    results.push({
      "id": Json(id),
      "source_scores": Json(scores),
      "pose_sha256": Json(hashes),
      "common": Json(n),
    })
  }
  guard max_angle < 1.0e-5 else {
    fail("MuJoCo xmat mismatch in radians: " + max_angle.to_string())
  }
  let result : Json = {
    "format": "moonrobo.orientation-source-controls.v1",
    "controls_sha256": Json(hash_file(controls_path)),
    "geometry_sha256": Json(hash_file(geometry + "/manifest.json")),
    "scene_sha256": Json(hash_file(dataset + "/scene.xml")),
    "max_body_angle_discrepancy_rad": Json(max_angle),
    "generator_sha256": Json(hash_file("/proc/self/exe")),
    "clips": Json(results),
  }
  @fs.write_file(
    output,
    @utf8.encode(result.stringify(indent=2)),
    create_mode=CreateNew,
  )
  result
}
