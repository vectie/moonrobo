///|
/// Refit the parent curriculum from its pinned sources on another E1 body.
/// Split membership and source tempo stay fixed; rejected fits remain reported.
pub async fn prepare_reembodied(
  base : String,
  target_directory : String,
  lab_assets : String,
  library : String,
  lafan : String,
  bones : String,
  scene : String,
  model_validation : String,
  output : String,
) -> Json {
  let parent = open_dataset(base)
  let prior = require_admission(base, parent, library)
  let target_data = open_dataset(target_directory)
  let robot = target_data.robot
  guard robot.joints.length() != parent.robot.joints.length() else {
    fail("reembodiment requires a different target joint profile")
  }
  let validation_bytes = read_bounded(model_validation, 4194304L)
  let validation = @json.parse(@utf8.decode(validation_bytes))
  guard validation is { "passed": True, .. } &&
    (json_field(validation, "target_profile") : Json) == Json(robot) &&
    (json_field(validation, "target_scene_sha256") : String) ==
    target_data.scene_sha256 &&
    (json_field(validation, "mujoco_sha256") : String) == hash_file(library) else {
    fail("target model validation does not match the new body")
  }
  guard (json_field(prior, "source_g1_scene_sha256") : String) ==
    hash_file(scene) else {
    fail("source G1 scene differs from parent retargeting")
  }
  let staging = output + ".partial"
  guard !@fs.exists(output) && !@fs.exists(staging) else {
    fail("reembodiment requires a fresh directory")
  }
  @fs.mkdir(staging + "/meshes", recursive=true)
  @fs.mkdir(staging + "/motions")
  @fs.mkdir(staging + "/reports")
  async fn copy(from : String, path : String) -> Unit {
    @fs.write_file(
      staging + "/" + path,
      read_bounded(from + "/" + path, 134217728L),
      create_mode=CreateNew,
    )
  }
  for name in ["scene.xml", "scene.json"] {
    copy(target_directory, name)
  }
  for name in @fs.readdir(target_directory + "/meshes") {
    copy(target_directory, "meshes/" + name)
  }
  for
    name in [
      "NOETIX-LICENSE", "LICENSE.dataset", "README.dataset.md", "BONES-SEED-LICENSE.md",
      "source-bones-selection.json", "source-g1-manifest.json",
    ] {
    copy(base, name)
  }
  @fs.write_file(
    staging + "/model-validation.json",
    validation_bytes,
    create_mode=CreateNew,
  )
  let paths = pinned_cross_robot_sources(base, lafan, bones)
  let target = @sim.Runtime::open(library, staging + "/scene.xml")
  let kin = @tracking.kinematics(
    target,
    names=robot.joints,
    tracked_names=robot.tracked,
    root_name="base_link",
  )
  let g1 = @sim.Runtime::open(library, scene)
  let g1_kin = @tracking.kinematics(g1)
  let g1_names = @aligned.joint_names()
  let g1_velocity = g1_names.map(name => @aligned.motor_of(name).velocity)
  let vendor = profile(joints=24)
  let vendor_rt = @sim.Runtime::open(
    library,
    lab_assets + "/robots/e1/mjcf/e1_24dof.xml",
    require_position_servos=false,
  )
  let vendor_kin = @tracking.kinematics(
    vendor_rt,
    names=vendor.joints,
    tracked_names=vendor.tracked,
    root_name="base_link",
  )
  let records : Array[Json] = json_field(prior, "accepted")
  let entries : Array[MotionEntry] = []
  let accepted : Array[Json] = []
  let rejected : Array[Json] = []
  for i, entry in parent.entries {
    let old = @json.parse(
      @utf8.decode(
        read_bounded(
          base + "/" + (json_field(records[i], "report") : String),
          4194304L,
        ),
      ),
    )
    guard old is { "source_start_frame": Null, .. } else {
      fail("reembodiment expects complete source recordings")
    }
    let (clip, fps, source_rt, source_kin, names, velocity, arms) = if entry.id.has_prefix(
        "vendor-",
      ) {
      let name = entry.id[7:].to_owned()
      guard ["dance1", "0_boxing", "135_02", "02_boxing"].contains(name) else {
        fail("unknown vendor source")
      }
      let bytes = read_bounded(
        lab_assets + "/datasets/mimic/" + name + ".npz",
        134217728L,
      )
      assert_eq(@artifacts.sha256(bytes), entry.source_sha256)
      let (clip, fps) = vendor_motion(bytes, name, vendor)
      (
        clip,
        fps,
        vendor_rt,
        vendor_kin,
        vendor.joints,
        vendor.velocity,
        Original,
      )
    } else {
      guard paths.get(entry.id) is Some((file, digest)) &&
        digest == entry.source_sha256 else {
        fail("missing pinned source " + entry.id)
      }
      let bytes = read_bounded(file, 67108864L)
      assert_eq(@artifacts.sha256(bytes), digest)
      let clip : @aligned.MotionClip = {
        name: entry.id,
        sha256: digest,
        rows: @aligned.parse_motion_csv(@utf8.decode(bytes)),
      }
      (
        clip,
        (json_field(old, "source_fps") : Double),
        g1,
        g1_kin,
        g1_names,
        g1_velocity,
        ArmsGuarded,
      )
    }
    let (fresh, report) = qualify_clip(
      clip,
      fps,
      source_rt,
      source_kin,
      names,
      velocity,
      target,
      kin,
      robot,
      entry.id,
      entry.split,
      staging,
      arms~,
    )
    for field in ["source_frames", "source_fps", "output_frames", "time_scale"] {
      assert_eq(
        (json_field(report, field) : Json),
        (json_field(old, field) : Json),
      )
    }
    match fresh {
      Some(item) => {
        assert_eq(item.source_sha256, entry.source_sha256)
        entries.push(item)
        let report_path = "reports/" + item.id + ".json"
        accepted.push({
          "id": item.id,
          "sha256": item.sha256,
          "split": item.split,
          "report": report_path,
          "report_sha256": hash_file(staging + "/" + report_path),
        })
      }
      None => rejected.push(report)
    }
  }
  let train = entries.filter(e => e.split == "train").length()
  let data : Dataset = { ..target_data, entries, }
  let bytes = @utf8.encode(Json(data).stringify(indent=2))
  @fs.write_file(staging + "/dataset.json", bytes, create_mode=CreateNew)
  let result : Json = {
    "format": "moonrobo.e1-dataset-admission.v2",
    "passed": train >= 3 && entries.length() > train,
    "dataset_sha256": @artifacts.sha256(bytes),
    "model_validation_sha256": hash_file(staging + "/model-validation.json"),
    "parent_dataset_sha256": hash_file(base + "/dataset.json"),
    "parent_admission_sha256": hash_file(base + "/admission.json"),
    "parent_profile": Json(parent.robot),
    "target_profile": Json(robot),
    "source_g1_scene_sha256": hash_file(scene),
    "generator_binary_sha256": hash_file("/proc/self/exe"),
    "candidate_count": parent.entries.length(),
    "training_clips": train,
    "validation_clips": entries.length() - train,
    "arm_orientation": "arms-guarded",
    "scope": "Parent source motions, split membership and tempo retained. Every reference refitted from source on the new body, including native E1 sources. Whole-body IK precedes guarded shoulder/elbow refinement. Excluded target fits remain in rejected reports.",
    "rules": reference_rules(),
    "accepted": accepted,
    "rejected": rejected,
  }
  @fs.write_file(
    staging + "/admission.json",
    @utf8.encode(result.stringify(indent=2)),
    create_mode=CreateNew,
  )
  ignore(require_admission(staging, data, library))
  @fs.rename(staging, output, replace=false)
  result
}
