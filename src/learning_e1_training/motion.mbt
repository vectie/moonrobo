///|
/// Vendor Isaac Lab breadth-first joint order, explicitly independent of the
/// SDK motor-slot order and MuJoCo depth-first order.
pub fn vendor_joint_names() -> Array[String] {
  [
    "l_leg_hip_yaw_joint", "r_leg_hip_yaw_joint", "waist_yaw_joint", "l_leg_hip_roll_joint",
    "r_leg_hip_roll_joint", "waist_roll_joint", "l_leg_hip_pitch_joint", "r_leg_hip_pitch_joint",
    "l_arm_shoulder_pitch_joint", "r_arm_shoulder_pitch_joint", "l_leg_knee_joint",
    "r_leg_knee_joint", "l_arm_shoulder_roll_joint", "r_arm_shoulder_roll_joint",
    "l_leg_ankle_pitch_joint", "r_leg_ankle_pitch_joint", "l_arm_shoulder_yaw_joint",
    "r_arm_shoulder_yaw_joint", "l_leg_ankle_roll_joint", "r_leg_ankle_roll_joint",
    "l_arm_elbow_pitch_joint", "r_arm_elbow_pitch_joint", "l_arm_elbow_yaw_joint",
    "r_arm_elbow_yaw_joint",
  ]
}

///|
/// Read numeric vendor NPZ; root is body 0 (base_link), quaternion WXYZ.
/// Velocities/body rewards are recomputed after projection and 50 Hz resampling.
pub fn vendor_motion(
  bytes : Bytes,
  name : String,
  robot : Profile,
) -> (@aligned.MotionClip, Double) raise {
  let arrays = @artifacts.decode_npz(bytes)
  guard arrays.get("fps") is Some(fps) &&
    fps.values.length() == 1 &&
    fps.values[0] > 0.0 &&
    fps.values[0] <= 1000.0 &&
    arrays.get("joint_pos") is Some(q) &&
    q.shape.length() == 2 &&
    q.shape[1] == 24 &&
    q.shape[0] >= 2 &&
    arrays.get("body_pos_w") is Some(p) &&
    p.shape.length() == 3 &&
    p.shape[0] == q.shape[0] &&
    p.shape[1] >= 1 &&
    p.shape[2] == 3 &&
    arrays.get("body_quat_w") is Some(r) &&
    r.shape == [q.shape[0], p.shape[1], 4] else {
    fail(
      "vendor E1 NPZ requires fps, joint_pos[T,24], body_pos_w[T,B,3], body_quat_w[T,B,4]",
    )
  }
  let indices = robot.joints.map(n => vendor_joint_names().search(n).unwrap())
  let rows = []
  for t in 0..<q.shape[0] {
    let row = p.values[t * p.shape[1] * 3:t * p.shape[1] * 3 + 3].to_owned()
    let quat = r.values[t * r.shape[1] * 4:t * r.shape[1] * 4 + 4].to_owned()
    guard quat.map(x => x * x).fold(init=0.0, (a, b) => a + b) > 1.0e-12 else {
      fail("zero reference quaternion")
    }
    row.append([quat[1], quat[2], quat[3], quat[0]])
    row.append(robot.embed(indices.map(j => q.values[t * 24 + j])))
    rows.push(row)
  }
  ({ name, sha256: @artifacts.sha256(bytes), rows, }, fps.values[0])
}

///|
pub(all) struct MotionEntry {
  id : String
  file : String
  sha256 : String
  source_sha256 : String
  split : String
  fps : Double
} derive(ToJson, FromJson)

///|
pub(all) struct Dataset {
  format : String
  robot : Profile
  scene_sha256 : String
  entries : Array[MotionEntry]
} derive(ToJson, FromJson)

///|
pub async fn load_motion(
  directory : String,
  dataset : Dataset,
  kin : @aligned.Kinematics,
  split : String,
) -> @aligned.MotionLibrary {
  let clips : Array[@aligned.MotionClip] = []
  for entry in dataset.entries {
    if entry.split != split {
      continue
    }
    guard !entry.file.contains("..") &&
      !entry.file.has_prefix("/") &&
      entry.fps == 50.0 else {
      fail("expected a 50 Hz E1 reference at a safe relative path")
    }
    let bytes = read_bounded(directory + "/" + entry.file, 67108864L)
    guard @artifacts.sha256(bytes) == entry.sha256 else {
      fail("E1 motion file digest differs")
    }
    let rows : Array[Array[Double]] = @json.from_json(
      @json.parse(@utf8.decode(bytes)),
    )
    guard rows.length() >= 2 && rows.length() <= 1000000 else {
      fail("E1 motion frame bound exceeded")
    }
    for row in rows {
      guard row.length() == 36 &&
        row.all(@numeric.finite) &&
        row[7 + dataset.robot.joints.length():].all(x => x == 0.0) else {
        fail("E1 reference dimensions, embedding or finite values differ")
      }
    }
    clips.push({ name: entry.id, sha256: entry.sha256, rows, })
  }
  guard !clips.is_empty() else { fail("empty E1 reference split: " + split) }
  @aligned.MotionLibrary::new(
    clips,
    kin,
    source_fps=50.0,
    exact_control_frames=true,
  )
}

///|
pub async fn read_bounded(path : String, limit : Int64) -> Bytes {
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  let size = file.size()
  guard size > 0L && size <= limit else {
    fail("E1 input exceeds byte bound: " + path)
  }
  file.read_exactly_at(size.to_int(), position=0L)
}
