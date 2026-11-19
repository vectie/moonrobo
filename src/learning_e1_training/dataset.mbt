///|
pub async fn prepare(
  lab_assets : String,
  output : String,
  joints~ : Int32 = 23,
) -> Json {
  let robot = profile(joints~)
  guard !@fs.exists(output) else {
    fail("E1 preparation requires a fresh directory")
  }
  let receipt = @assets.prepare_embedded_scene(
    lab_assets + "/robots/e1/mjcf/e1_24dof.xml",
    lab_assets + "/robots/e1/meshes",
    output,
    robot.joints,
    robot.stiffness,
    robot.damping,
    robot.effort,
    robot.armature,
    locked_joint=if joints == 23 { Some("waist_roll_joint") } else { None },
  )
  @fs.mkdir(output + "/motions")
  let entries : Array[MotionEntry] = []
  for i, name in ["dance1", "0_boxing", "135_02", "02_boxing"] {
    let source = lab_assets + "/datasets/mimic/" + name + ".npz"
    let bytes = read_bounded(source, 134217728L)
    let (clip, fps) = vendor_motion(bytes, name, robot)
    // Resample each clip independently so mixed vendor FPS cannot be relabeled.
    let empty_kin : @aligned.Kinematics = {
      bodies: [],
      tracked: [],
      q_lo: [],
      q_hi: [],
    }
    let sampled = @aligned.MotionLibrary::new(
      [clip],
      empty_kin,
      source_fps=fps,
      compute_body_features=false,
    )
    let rows = []
    for frame in 0..<sampled.states.length() {
      let s = sampled.states[frame]
      let quat = @aligned.mat_to_quat(s.rotation)
      let row = s.p.copy()
      row.append([quat[1], quat[2], quat[3], quat[0]])
      row.append(s.q)
      rows.push(row)
    }
    let data = @utf8.encode(Json(rows).stringify())
    let file = "motions/" + name + ".json"
    @fs.write_file(output + "/" + file, data, create_mode=CreateNew)
    entries.push({
      id: name,
      file,
      sha256: @artifacts.sha256(data),
      source_sha256: clip.sha256,
      split: if i < 2 {
        "train"
      } else {
        "validation"
      },
      fps: 50.0,
    })
  }
  let scene_bytes = read_bounded(output + "/scene.xml", 4194304L)
  let dataset : Dataset = {
    format: "moonrobo.e1-dataset.v1",
    robot,
    scene_sha256: @artifacts.sha256(scene_bytes),
    entries,
  }
  @fs.write_file(
    output + "/dataset.json",
    @utf8.encode(Json(dataset).stringify(indent=2)),
    create_mode=CreateNew,
  )
  let result : Json = {
    "dataset": Json(dataset),
    "scene_receipt": receipt,
    "motion_transform": "vendor 24-axis NPZ in Isaac joint order; base_link root WXYZ; reorder, optional zero waist-roll lock, zero embedding, resample to 50 Hz; recompute FK and velocities",
    "validation_scope": "separate vendor files; source-subject/action independence not established",
    "profile_scope": "vendor simulation parameters; 23-axis scene derived by fixing waist roll; physical calibration pending",
  }
  @fs.write_file(
    output + "/preparation.json",
    @utf8.encode(result.stringify(indent=2)),
    create_mode=CreateNew,
  )
  result
}

///|
pub async fn open_dataset(directory : String) -> Dataset {
  let bytes = read_bounded(directory + "/dataset.json", 1048576L)
  let dataset : Dataset = @json.from_json(@json.parse(@utf8.decode(bytes)))
  guard dataset.format == "moonrobo.e1-dataset.v1" &&
    Json(dataset.robot) == Json(profile(joints=dataset.robot.joints.length())) &&
    dataset.entries.length() > 0 &&
    dataset.entries.length() <= 10000 else {
    fail("invalid E1 dataset/profile")
  }
  let names : Map[String, Bool] = {}
  let sources : Map[String, String] = {}
  for entry in dataset.entries {
    guard !names.contains(entry.id) &&
      entry.fps == 50.0 &&
      ["train", "validation", "test"].contains(entry.split) else {
      fail("duplicate E1 motion identity or unsupported FPS/split")
    }
    names[entry.id] = true
    if sources.get(entry.source_sha256) is Some(split) {
      guard split == entry.split else {
        fail("E1 source motion leaks across splits")
      }
    }
    sources[entry.source_sha256] = entry.split
  }
  let scene = read_bounded(directory + "/scene.xml", 4194304L)
  guard @artifacts.sha256(scene) == dataset.scene_sha256 else {
    fail("E1 scene digest differs")
  }
  let receipt = @json.parse(
    @utf8.decode(read_bounded(directory + "/scene.json", 1048576L)),
  )
  guard receipt is Object(fields) && fields.get("meshes") is Some(mesh_value) else {
    fail("missing scene mesh receipt")
  }
  let meshes : Map[String, String] = @json.from_json(mesh_value)
  for name, digest in meshes {
    guard !name.contains("/") && !name.contains("\\") else {
      fail("invalid E1 mesh path")
    }
    guard @artifacts.sha256(
        read_bounded(directory + "/meshes/" + name, 67108864L),
      ) ==
      digest else {
      fail("E1 mesh digest differs: " + name)
    }
  }
  dataset
}
