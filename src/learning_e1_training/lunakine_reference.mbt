///|
/// Export goals with the same reference encoder used by training. No new
/// geometry implementation belongs in deployment; these are raw, unnormalized
/// previews. This conversion does not certify reference quality or E1 control.
pub fn lunakine_reference(
  motion : @aligned.MotionLibrary,
  clip_index : Int32,
  robot : Profile,
  bundle : @deployed.Bundle,
) -> Json raise {
  guard clip_index >= 0 &&
    clip_index < motion.names.length() &&
    motion.clip_start.length() == motion.names.length() &&
    motion.clip_end.length() == motion.names.length() &&
    motion.source_sha256.length() == motion.names.length() &&
    robot.id == bundle.profile_id() &&
    robot.joints.length() == bundle.joints().length() else {
    fail("E1 reference source or deployment profile differs")
  }
  for i, joint in robot.joints {
    guard joint == bundle.joints()[i] else {
      fail("E1 reference source joint order differs")
    }
  }
  let start = motion.clip_start[clip_index]
  let end = motion.clip_end[clip_index]
  guard start >= 0 &&
    end > start &&
    end < motion.states.length() &&
    motion.clip_id.length() == motion.states.length() else {
    fail("invalid E1 reference clip bounds")
  }
  for index in start..<=end {
    let state = motion.states[index]
    guard motion.clip_id[index] == clip_index &&
      state.p.length() == 3 &&
      state.v.length() == 3 &&
      state.w.length() == 3 &&
      state.rotation.length() == 9 &&
      state.q.length() == 29 &&
      state.qd.length() == 29 &&
      [state.p, state.v, state.w, state.rotation, state.q, state.qd].all(values => {
        values.all(@numeric.finite)
      }) &&
      state.q[robot.joints.length():].all(x => x == 0.0) &&
      state.qd[robot.joints.length():].all(x => x == 0.0) else {
      fail("E1 reference state geometry or physical embedding differs")
    }
  }
  let value : Json = {
    "format": "moonrobo.e1-actor-reference.v1",
    "profile_id": bundle.profile_id(),
    "joints": Json(bundle.joints()),
    "reference_id": motion.names[clip_index],
    "source_sha256": motion.source_sha256[clip_index],
    "control_dt_ms": 20,
    "goal_layout": "aligned.preview73.v1",
    "frames": Json(
      Array::makei(end - start + 1, step => {
        let index = start + step
        let frame : Json = {
          "goals": Json(motion.goal(index, bundle.goal_width() / 73)),
          "body_to_world": Json(motion.states[index].rotation),
        }
        frame
      }),
    ),
    "scope": "prepared training previews; no physical qualification",
  }
  // Validate once before writing, using the same deployment reader.
  ignore(@reference.Clip::parse(bundle, value))
  value
}

///|
/// Offline conversion from an existing E1 dataset. Requires its normal asset
/// identity checks, but opens no simulator, tensor backend, SDK or accelerator.
pub async fn export_lunakine_reference(
  dataset_directory : String,
  bundle_directory : String,
  clip_id : String,
  output : String,
  split~ : String = "validation",
) -> Json {
  guard !@fs.exists(output) else {
    fail("reference export requires a new output file")
  }
  let dataset = open_dataset(dataset_directory)
  let bundle = @deployed.Bundle::read(bundle_directory)
  let empty_kin : @aligned.Kinematics = {
    bodies: [],
    tracked: [],
    q_lo: [],
    q_hi: [],
  }
  let motion = load_motion(dataset_directory, dataset, empty_kin, split)
  guard motion.names.search(clip_id) is Some(index) else {
    fail("reference clip is absent from selected split")
  }
  let value = lunakine_reference(motion, index, dataset.robot, bundle)
  @fs.write_file(output, @utf8.encode(value.stringify()), create_mode=CreateNew)
  {
    "reference": output,
    "reference_id": clip_id,
    "profile_id": bundle.profile_id(),
    "frames": motion.clip_end[index] - motion.clip_start[index] + 1,
    "published": false,
    "hardware_qualified": false,
  }
}
