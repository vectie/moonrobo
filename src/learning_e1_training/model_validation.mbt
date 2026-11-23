///|
fn vendor_body_names() -> Array[String] {
  [
    "base_link", "l_leg_hip_yaw_link", "r_leg_hip_yaw_link", "waist_yaw_link", "l_leg_hip_roll_link",
    "r_leg_hip_roll_link", "waist_roll_link", "l_leg_hip_pitch_link", "r_leg_hip_pitch_link",
    "l_arm_shoulder_pitch_link", "r_arm_shoulder_pitch_link", "l_leg_knee_link",
    "r_leg_knee_link", "l_arm_shoulder_roll_link", "r_arm_shoulder_roll_link", "l_leg_ankle_pitch_link",
    "r_leg_ankle_pitch_link", "l_arm_shoulder_yaw_link", "r_arm_shoulder_yaw_link",
    "l_leg_ankle_roll_link", "r_leg_ankle_roll_link", "l_arm_elbow_pitch_link", "r_arm_elbow_pitch_link",
    "l_arm_elbow_yaw_link", "r_arm_elbow_yaw_link",
  ]
}

///|
fn state_of_row(row : Array[Double]) -> @aligned.State {
  {
    p: row[:3].to_owned(),
    rotation: @aligned.quat_to_mat([row[6], row[3], row[4], row[5]]),
    q: row[7:].to_owned(),
    qd: Array::make(29, 0.0),
    v: [0.0, 0.0, 0.0],
    w: [0.0, 0.0, 0.0],
  }
}

///|
fn set_pose(
  rt : @sim.Runtime,
  layout : @aligned.JointLayout,
  s : @aligned.State,
) -> Unit raise {
  let raw = Array::make(layout.nq + layout.nv + layout.na, 0.0)
  let quat = @aligned.mat_to_quat(s.rotation)
  for i in 0..<3 {
    raw[i] = s.p[i]
  }
  for i in 0..<4 {
    raw[3 + i] = quat[i]
  }
  for i, address in layout.qpos_addresses {
    raw[address] = s.q[i]
  }
  rt.set_state(raw)
}

///|
fn distance(a : Array[Double], b : Array[Double]) -> Double {
  @aligned.vec_sub(a, b).map(x => x * x).fold(init=0.0, (x, y) => x + y).sqrt()
}

///|
fn angle(a : Array[Double], b : Array[Double]) -> Double {
  let r = @aligned.mat_mul(@aligned.transpose(a), b)
  @math.acos(((r[0] + r[4] + r[8] - 1.0) * 0.5).max(-1.0).min(1.0))
}

///|
/// Independent native MuJoCo, MoonBit FK, URDF and recorded NPZ checks.
/// Qualification is for a versioned simulator; hardware calibration is separate.
pub async fn validate_model(
  lab_assets : String,
  library : String,
  target_directory : String,
  output : String,
) -> Json {
  guard !@fs.exists(output) else {
    fail("model validation requires fresh output")
  }
  @fs.mkdir(output, recursive=true)
  let xml_file = lab_assets + "/robots/e1/mjcf/e1_24dof.xml"
  let urdf_file = lab_assets + "/robots/e1/urdf/e1_24dof.urdf"
  let urdf = @utf8.decode(read_bounded(urdf_file, 4194304L))
  guard urdf.split("</robot>").collect().length() == 2 else {
    fail("invalid source URDF")
  }
  let input = urdf
    .replace_all(old="../meshes/", new=lab_assets + "/robots/e1/meshes/")
    .replace_all(
      old="</robot>",
      new="<mujoco><compiler discardvisual=\"true\" fusestatic=\"false\" balanceinertia=\"true\"/></mujoco></robot>",
    )
  @fs.write_file(
    output + "/source.urdf",
    @utf8.encode(input),
    create_mode=CreateNew,
  )
  ignore(
    @sim.compile_xml_to_mjcf(
      library,
      output + "/source.urdf",
      output + "/source.xml",
    ),
  )
  let compiled = @utf8.decode(read_bounded(output + "/source.xml", 4194304L))
  guard compiled.find("<body name=\"base_link\"") is Some(start) &&
    compiled[start:].find(">") is Some(end) else {
    fail("compiled URDF lost named root")
  }
  let at = start + end + 1
  let robot = profile(joints=24)
  let actuators = "<actuator>" +
    robot.joints
    .map(name => {
      "<position name=\"" + name + "\" joint=\"" + name + "\" kp=\"1\"/>"
    })
    .join("") +
    "</actuator>"
  let floating = (compiled[:at].to_owned() +
  "<freejoint name=\"audit_root\"/>" +
  compiled[at:].to_owned()).replace_all(
    old="</mujoco>",
    new=actuators + "</mujoco>",
  )
  @fs.write_file(
    output + "/source-floating.xml",
    @utf8.encode(floating),
    create_mode=CreateNew,
  )
  // The pristine vendor MJCF uses torque motors. Open it without requiring
  // position-servo semantics; no dynamics step is executed by this audit.
  let mjcf = @sim.Runtime::open(
    library,
    xml_file,
    require_position_servos=false,
  )
  let urt = @sim.Runtime::open(library, output + "/source-floating.xml")
  let target = @sim.Runtime::open(library, target_directory + "/scene.xml")
  let target_data = open_dataset(target_directory)
  target.configure_collision(true)
  let target_layout = @tracking.joint_layout(
    target,
    names=target_data.robot.joints,
  )
  let bodies = vendor_body_names()
  let kin = @tracking.kinematics(
    mjcf,
    names=robot.joints,
    tracked_names=bodies,
    root_name="base_link",
  )
  let ukin = @tracking.kinematics(
    urt,
    names=robot.joints,
    tracked_names=bodies,
    root_name="base_link",
  )
  let tkin = @tracking.kinematics(
    target,
    names=target_data.robot.joints,
    tracked_names=bodies,
    root_name="base_link",
  )
  let layout = @tracking.joint_layout(mjcf, names=robot.joints)
  let native_ids = bodies.map(name => {
    let mut id = -1
    for i in 1..<mjcf.body_count() {
      if mjcf.body_name(i) == name {
        id = i
      }
    }
    guard id > 0 else { fail("source model misses named body") }
    id
  })
  let clips : Array[Json] = []
  let mut maximum_fk = 0.0
  let mut maximum_source = 0.0
  let mut maximum_urdf = 0.0
  let mut maximum_source_angle = 0.0
  let mut maximum_lock = 0.0
  let mut accepted_sources = 0
  for name in ["dance1", "0_boxing", "135_02", "02_boxing"] {
    let bytes = read_bounded(
      lab_assets + "/datasets/mimic/" + name + ".npz",
      134217728L,
    )
    let arrays = @artifacts.decode_npz(bytes)
    let (clip, _) = vendor_motion(bytes, name, robot)
    guard arrays.get("body_pos_w") is Some(positions) &&
      arrays.get("body_quat_w") is Some(rotations) &&
      positions.shape[1] == bodies.length() else {
      fail("source body identity/count mismatch")
    }
    let mut mp = 0.0
    let mut mr = 0.0
    let mut up = 0.0
    let mut lp = 0.0
    let mut sample_count = 0
    let mut contact_depth = 0.0
    let mut contact_bodies : Array[String] = []
    for sample in 0..<33 {
      let f = sample * (clip.rows.length() - 1) / 32
      let s = state_of_row(clip.rows[f])
      let fk = kin.forward(s)
      let ufk = ukin.forward(s)
      set_pose(mjcf, layout, s)
      let locked_q = s.q.copy()
      // The source must have the same available axes as the target. The
      // 24-axis scene retains waist roll; only the 23-axis scene locks it.
      if !target_data.robot.joints.contains("waist_roll_joint") {
        locked_q[robot.joints.search("waist_roll_joint").unwrap()] = 0.0
      }
      let locked_fk = kin.forward({ ..s, q: locked_q, })
      let projected = target_data.robot.embed(
        target_data.robot.joints.map(j => s.q[robot.joints.search(j).unwrap()]),
      )
      let tfk = tkin.forward({ ..s, q: projected, })
      set_pose(target, target_layout, { ..s, q: projected, })
      if target.self_penetration() > contact_depth {
        contact_depth = target.self_penetration()
        contact_bodies = target.self_contact_bodies()
      }
      for b in 0..<bodies.length() {
        let offset = (f * bodies.length() + b) * 3
        let roffset = (f * bodies.length() + b) * 4
        let ep = distance(
          fk[b].p,
          positions.values[offset:offset + 3].to_owned(),
        )
        let er = angle(
          fk[b].rotation,
          @aligned.quat_to_mat(rotations.values[roffset:roffset + 4].to_owned()),
        )
        mp = mp.max(ep)
        mr = mr.max(er)
        up = up.max(distance(fk[b].p, ufk[b].p))
        lp = lp.max(distance(locked_fk[b].p, tfk[b].p))
        maximum_fk = maximum_fk.max(
          distance(fk[b].p, mjcf.body_world_pos(native_ids[b])),
        )
      }
      sample_count += 1
    }
    maximum_source = maximum_source.max(mp)
    maximum_source_angle = maximum_source_angle.max(mr)
    maximum_urdf = maximum_urdf.max(up)
    maximum_lock = maximum_lock.max(lp)
    let source_passed = mp < 0.005 && mr < 0.01
    if source_passed {
      accepted_sources += 1
    }
    clips.push({
      "clip": name,
      "passed": source_passed,
      "samples": sample_count,
      "recorded_position_max_m": mp,
      "recorded_rotation_max_rad": mr,
      "urdf_mjcf_position_max_m": up,
      "locked_model_position_max_m": lp,
      "source_sha256": @artifacts.sha256(bytes),
      "projected_self_penetration_m": contact_depth,
      "projected_contact_bodies": contact_bodies,
    })
  }
  let passed = maximum_fk < 1.0e-8 &&
    maximum_lock < 1.0e-8 &&
    maximum_urdf < 0.005 &&
    accepted_sources > 0
  let result : Json = {
    "format": "moonrobo.e1-model-validation.v1",
    "passed": passed,
    "native_vs_moonbit_fk_max_m": maximum_fk,
    "source_record_position_max_m": maximum_source,
    "source_record_rotation_max_rad": maximum_source_angle,
    "urdf_vs_mjcf_max_m": maximum_urdf,
    "locked_variant_vs_source_max_m": maximum_lock,
    "target_waist_roll_locked": !target_data.robot.joints.contains(
      "waist_roll_joint",
    ),
    "clips": clips,
    "accepted_source_clips": accepted_sources,
    "source_clips_all_passed": accepted_sources == clips.length(),
    "source_mjcf_sha256": hash_file(xml_file),
    "source_urdf_sha256": hash_file(urdf_file),
    "target_scene_sha256": hash_file(target_directory + "/scene.xml"),
    "mujoco_sha256": hash_file(library),
    "target_profile": Json(target_data.robot),
    "hardware_calibrated": false,
    "thresholds": {
      "native_fk_m": 1.0e-8,
      "locked_model_m": 1.0e-8,
      "urdf_m": 0.005,
      "recorded_m": 0.005,
      "recorded_rad": 0.01,
    },
  }
  @fs.write_file(
    output + "/validation.json",
    @utf8.encode(result.stringify(indent=2)),
    create_mode=CreateNew,
  )
  result
}
