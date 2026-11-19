///|
fn[T : FromJson] json_field(value : Json, key : String) -> T raise {
  guard value is Object(fields) && fields.get(key) is Some(v) else {
    fail("missing qualification field: " + key)
  }
  @json.from_json(v)
}

///|
fn id_of_body(rt : @sim.Runtime, name : String) -> Int32 raise {
  for b in 1..<rt.body_count() {
    if rt.body_name(b) == name {
      return b
    }
  }
  fail("missing qualification body: " + name)
}

///|
const Self_penetration_limit_m : Double = 0.02

///|
/// Maximum penetration per unordered pair on the same control frames as
/// screen_reference. A knee contact cannot provide clearance for an elbow.
fn pair_peaks(
  rows : Array[Array[Double]],
  kin : @aligned.Kinematics,
  rt : @sim.Runtime,
  robot : Profile,
  exact_control_frames~ : Bool,
) -> Map[Int32, Double] raise {
  let motion = @aligned.MotionLibrary::new(
    [{ name: "arm-contact-check", sha256: "in-memory", rows, }],
    kin,
    source_fps=50.0,
    exact_control_frames~,
    compute_body_features=false,
  )
  rt.configure_collision(true)
  let layout = @tracking.joint_layout(rt, names=robot.joints)
  let count = rt.body_count()
  let peaks : Map[Int32, Double] = {}
  for frame in 0..<motion.states.length() {
    set_pose(rt, layout, motion.states[frame])
    for c in rt.collision_contacts() {
      if c.body_a > 0 && c.body_b > 0 && c.distance < 0.0 {
        let pair = c.body_a.min(c.body_b) * count + c.body_a.max(c.body_b)
        peaks[pair] = peaks.get(pair).unwrap_or(0.0).max(-c.distance)
      }
    }
  }
  peaks
}

///|
fn reference_rules() -> Json {
  {
    "format": "moonrobo.e1-reference-rules.v3",
    "body_rms_m": 0.06,
    "root_orientation_deviation_rad": 0.5,
    "stance_position_m": 0.03,
    "stance_rotation_rad": 0.15,
    "self_penetration_m": Self_penetration_limit_m,
    "sole_penetration_m": 0.025,
    "body_origin_penetration_m": 0.12,
    "elevated_height_m": 0.20,
    "elevated_duration_s": 0.6,
    "floating_sole_m": 0.02,
    "floating_duration_s": 0.5,
    "root_standing_height_m": 0.6,
    "root_standing_upright": 0.9,
    "root_stationary_speed_m_s": 0.15,
    "maximum_floor_alignment_m": 0.15,
    "control_hz": 50,
    "scope": "predeclared E1 kinematic/geometric curriculum filter; not dynamic certification or paper-exact G1 filtering",
  }
}

///|
fn screen_reference(
  rows : Array[Array[Double]],
  quality : Json,
  kin : @aligned.Kinematics,
  rt : @sim.Runtime,
  robot : Profile,
  exact_control_frames~ : Bool = false,
  floor_already_aligned~ : Bool = false,
) -> (Array[Array[Double]], Json) raise {
  let flags : Array[Array[Bool]] = json_field(quality, "stance_flags")
  guard flags.length() == rows.length() else {
    fail("stance/reference lengths differ")
  }
  let layout = @tracking.joint_layout(rt, names=robot.joints)
  let feet = [
    id_of_body(rt, "l_leg_ankle_roll_link"),
    id_of_body(rt, "r_leg_ankle_roll_link"),
  ]
  rt.configure_collision(true)
  let ground_samples = []
  for f, row in rows {
    if flags[f].any(x => x) {
      set_pose(rt, layout, state_of_row(row))
      for k, b in feet {
        if flags[f][k] {
          ground_samples.push(rt.body_floor_distance(b))
        }
      }
    }
  }
  let reasons : Array[String] = []
  let shift = if ground_samples.is_empty() {
    reasons.push("no_inferred_stance_for_floor_alignment")
    0.0
  } else {
    ground_samples.sort()
    let correction = -ground_samples[ground_samples.length() / 2]
    if floor_already_aligned {
      guard correction.abs() < 1.0e-7 else {
        fail("fixed base changed the support plane")
      }
      0.0
    } else {
      correction
    }
  }
  if shift.abs() > 0.15 {
    reasons.push("excessive_floor_alignment")
  }
  let corrected = rows.map(row => {
    let r = row.copy()
    r[2] += shift
    r
  })
  let clip : @aligned.MotionClip = {
    name: "candidate",
    sha256: "in-memory",
    rows: corrected,
  }
  let motion = @aligned.MotionLibrary::new(
    [clip],
    kin,
    source_fps=50.0,
    exact_control_frames~,
  )
  let mut position_bad = 0
  let mut speed_bad = 0
  let mut maximum_self = 0.0
  let mut collision_frame : Int32? = None
  let mut collision_bodies : Array[String] = []
  let mut minimum_sole = 1.0e9
  let mut minimum_body = 1.0e9
  let mut elevated = 0
  let mut maximum_elevated = 0
  let mut floating = 0
  let mut maximum_floating = 0
  let mut maximum_speed_ratio = 0.0
  for f in 0..<motion.states.length() {
    let s = motion.states[f]
    set_pose(rt, layout, s)
    let depth = rt.self_penetration()
    if depth > maximum_self {
      maximum_self = depth
      collision_frame = Some(f)
      collision_bodies = rt.self_contact_bodies()
    }
    let l = rt.body_floor_distance(feet[0])
    let r = rt.body_floor_distance(feet[1])
    minimum_sole = minimum_sole.min(l).min(r)
    let mut low = 1.0e9
    for body in kin.forward(s, all_bodies=true) {
      low = low.min(body.p[2])
    }
    minimum_body = minimum_body.min(low)
    elevated = if low > 0.20 { elevated + 1 } else { 0 }
    maximum_elevated = maximum_elevated.max(elevated)
    let stationary = s.v.map(x => x * x).fold(init=0.0, (a, b) => a + b).sqrt() <
      0.15 &&
      s.w.map(x => x * x).fold(init=0.0, (a, b) => a + b).sqrt() < 0.2
    floating = if l > 0.02 &&
      r > 0.02 &&
      s.p[2] > 0.6 &&
      s.rotation[8] > 0.9 &&
      stationary {
      floating + 1
    } else {
      0
    }
    maximum_floating = maximum_floating.max(floating)
    for j in 0..<robot.joints.length() {
      if s.q[j] < kin.q_lo[j] - 1.0e-6 || s.q[j] > kin.q_hi[j] + 1.0e-6 {
        position_bad += 1
      }
      if f > 0 {
        let speed = (s.q[j] - motion.states[f - 1].q[j]).abs() * 50.0
        maximum_speed_ratio = maximum_speed_ratio.max(speed / robot.velocity[j])
        if speed > robot.velocity[j] + 1.0e-5 {
          speed_bad += 1
        }
      }
    }
  }
  let body_rms : Double = json_field(quality, "body_rms_m")
  let stance_position : Double = json_field(quality, "stance_position_max_m")
  let stance_rotation : Double = json_field(quality, "stance_rotation_max_rad")
  let root_rotation : Double = json_field(
    quality, "root_rotation_deviation_max_rad",
  )
  if root_rotation > 0.500001 {
    reasons.push("root_orientation_deviation")
  }
  if body_rms > 0.06 {
    reasons.push("task_body_rms")
  }
  if stance_position > 0.03 {
    reasons.push("stance_position")
  }
  if stance_rotation > 0.15 {
    reasons.push("stance_orientation")
  }
  if position_bad > 0 {
    reasons.push("joint_range")
  }
  if speed_bad > 0 {
    reasons.push("joint_speed")
  }
  if maximum_self > Self_penetration_limit_m {
    reasons.push("self_collision")
  }
  if minimum_sole < -0.025 {
    reasons.push("sole_penetration")
  }
  if minimum_body < -0.12 {
    reasons.push("body_origin_penetration")
  }
  if maximum_elevated >= 30 {
    reasons.push("elevated_support")
  }
  if maximum_floating >= 25 {
    reasons.push("stationary_floating_feet")
  }
  let result : Json = {
    "accepted": reasons.is_empty(),
    "reasons": reasons,
    "rules": reference_rules(),
    "frames": corrected.length(),
    "floor_alignment_m": shift,
    "stance_anchor_samples": ground_samples.length(),
    "position_limit_violations": position_bad,
    "velocity_limit_violations": speed_bad,
    "maximum_reference_speed_ratio": maximum_speed_ratio,
    "maximum_self_penetration_m": maximum_self,
    "maximum_self_penetration_frame": match collision_frame {
      Some(frame) => Json(frame)
      None => Json(())
    },
    "maximum_self_penetration_bodies": collision_bodies,
    "minimum_sole_distance_m": minimum_sole,
    "minimum_body_origin_z_m": minimum_body,
    "maximum_elevated_frames": maximum_elevated,
    "maximum_floating_frames": maximum_floating,
    "body_rms_m": body_rms,
    "stance_position_max_m": stance_position,
    "stance_rotation_max_rad": stance_rotation,
    "root_orientation_deviation_max_rad": root_rotation,
    "geometry_distance": "native mj_geomDistance: actual foot collision geoms to floor plane",
    "dynamic_tracking_certified": false,
  }
  (corrected, result)
}

///|
/// Called before GPU allocation. Identity checks and quality admission are
/// separate requirements; unqualified artifacts cannot enter a normal run.
async fn require_admission(
  directory : String,
  dataset : Dataset,
  library : String,
) -> Json {
  let admission = @json.parse(
    @utf8.decode(read_bounded(directory + "/admission.json", 4194304L)),
  )
  guard admission is { "format": String(format), "passed": True, .. } &&
    ["moonrobo.e1-dataset-admission.v2", "moonrobo.e1-locomotion-admission.v1"].contains(
      format,
    ) else {
    fail("E1 dataset has no accepted motion qualification")
  }
  let digest : String = json_field(admission, "dataset_sha256")
  guard digest == hash_file(directory + "/dataset.json") else {
    fail("qualified E1 dataset identity changed")
  }
  let validation_digest : String = json_field(
    admission, "model_validation_sha256",
  )
  guard validation_digest == hash_file(directory + "/model-validation.json") else {
    fail("E1 model validation identity changed")
  }
  let validation = @json.parse(
    @utf8.decode(read_bounded(directory + "/model-validation.json", 4194304L)),
  )
  guard validation is { "passed": True, .. } else {
    fail("E1 model validation failed")
  }
  let expected_scene : String = json_field(validation, "target_scene_sha256")
  let expected_runtime : String = json_field(validation, "mujoco_sha256")
  guard expected_scene == dataset.scene_sha256 &&
    expected_runtime == hash_file(library) &&
    (json_field(validation, "target_profile") : Json) == Json(dataset.robot) else {
    fail("qualified E1 model/runtime differs from training")
  }
  let accepted : Array[Json] = json_field(admission, "accepted")
  guard accepted.length() == dataset.entries.length() &&
    accepted.length() > 0 &&
    (json_field(admission, "rules") : Json) == reference_rules() &&
    dataset.entries.filter(e => e.split == "train").length() >= 3 &&
    dataset.entries.filter(e => e.split == "validation").length() >= 1 else {
    fail("admission does not cover the whole catalog or minimum curriculum")
  }
  for i, entry in dataset.entries {
    guard !entry.file.contains("..") &&
      !entry.file.has_prefix("/") &&
      hash_file(directory + "/" + entry.file) == entry.sha256 else {
      fail("qualified motion bytes differ before learner allocation")
    }
    let record = accepted[i]
    guard (json_field(record, "id") : String) == entry.id &&
      (json_field(record, "sha256") : String) == entry.sha256 &&
      (json_field(record, "split") : String) == entry.split else {
      fail("qualified motion order/hash/split differs")
    }
    let name : String = json_field(record, "report")
    guard !name.contains("..") &&
      !name.has_prefix("/") &&
      (json_field(record, "report_sha256") : String) ==
      hash_file(directory + "/" + name) else {
      fail("qualified motion report differs")
    }
    let report = @json.parse(
      @utf8.decode(read_bounded(directory + "/" + name, 4194304L)),
    )
    guard (json_field(report, "id") : String) == entry.id &&
      (json_field(report, "output_sha256") : String) == entry.sha256 &&
      (json_field(report, "source_sha256") : String) == entry.source_sha256 &&
      (json_field(report, "split") : String) == entry.split else {
      fail("qualification report does not describe this motion")
    }
    guard report is { "screen": { "accepted": True, "rules": rules, .. }, .. } &&
      rules == reference_rules() else {
      fail("motion lacks matching acceptance rules")
    }
    if format == "moonrobo.e1-locomotion-admission.v1" {
      guard report is { "local_dynamics": { "accepted": True, .. }, .. } else {
        fail("locomotion motion failed local dynamics admission")
      }
    }
  }
  admission
}
