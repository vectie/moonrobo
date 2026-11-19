///|
/// Write a separate candidate; never admit an IK-only candidate silently to the
/// immutable training split. The report preserves the full clip denominator.
pub async fn retarget_file(
  dataset_directory : String,
  mujoco_library : String,
  g1_scene : String,
  csv : String,
  fps : Double,
  output : String,
  legacy_positional~ : Bool = false,
  arms~ : ArmOrientation = Original,
) -> Json {
  guard !legacy_positional || arms == Original else {
    fail("arm orientation requires whole-body IK")
  }
  guard !@fs.exists(output) else {
    fail("retarget output must be a fresh directory")
  }
  let dataset = open_dataset(dataset_directory)
  let source_rt = @sim.Runtime::open(mujoco_library, g1_scene)
  let source_kin = @tracking.kinematics(source_rt)
  let target_rt = @sim.Runtime::open(
    mujoco_library,
    dataset_directory + "/scene.xml",
  )
  let target_kin = @tracking.kinematics(
    target_rt,
    names=dataset.robot.joints,
    tracked_names=dataset.robot.tracked,
    root_name="base_link",
  )
  let bytes = read_bounded(csv, 67108864L)
  let clip : @aligned.MotionClip = {
    name: "g1-source",
    sha256: @artifacts.sha256(bytes),
    rows: @aligned.parse_motion_csv(@utf8.decode(bytes)),
  }
  let library = @aligned.MotionLibrary::new(
    [clip],
    source_kin,
    source_fps=fps,
    compute_body_features=false,
  )
  let (rows, quality) = if legacy_positional {
    retarget(library, source_kin, target_kin, dataset.robot)
  } else {
    let (rows, quality, screen, alignment) = fit_screened_reference(
      library,
      clip,
      source_kin,
      target_rt,
      target_kin,
      dataset.robot,
      smooth=false,
      arms~,
      exact_control_frames=true,
    )
    guard quality is Object(fields) else { fail("invalid retarget report") }
    ignore(fields.remove("stance_flags"))
    fields["accepted"] = Json(
      (json_field(screen, "accepted") : Bool) &&
      (json_field(quality, "rejected_foot_samples") : Int32) == 0,
    )
    fields["first_floor_alignment_m"] = Json(alignment)
    fields["screen"] = screen
    (rows, quality)
  }
  @fs.mkdir(output, recursive=true)
  let data = @utf8.encode(Json(rows).stringify())
  @fs.write_file(output + "/motion.json", data, create_mode=CreateNew)
  let report : Json = {
    "format": if legacy_positional {
      "moonrobo.e1-retarget-candidate.v1"
    } else {
      "moonrobo.e1-retarget-candidate.v2"
    },
    "robot": Json(dataset.robot),
    "source_sha256": Json(clip.sha256),
    "source_scene_sha256": Json(hash_file(g1_scene)),
    "source_fps": Json(fps),
    "output_fps": 50,
    "output_sha256": Json(@artifacts.sha256(data)),
    "target_dataset_sha256": Json(
      hash_file(dataset_directory + "/dataset.json"),
    ),
    "quality": quality,
    "training_catalog_admitted": false,
  }
  @fs.write_file(
    output + "/retarget.json",
    @utf8.encode(report.stringify(indent=2)),
    create_mode=CreateNew,
  )
  report
}
