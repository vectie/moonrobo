///|
test "prepared references preserve training previews clip boundaries and physical embedding" {
  let mut compared = 0
  for count in [23, 24] {
    let robot = profile(joints=count)
    let clips = Array::makei(2, clip => {
      let rows = Array::makei(if clip == 0 { 3 } else { 5 }, step => {
        let angle = step.to_double() * 0.13 + clip.to_double() * 0.4
        let quaternion = @aligned.mat_to_quat(
          @aligned.quat_to_mat([0.7, angle, 0.2, -0.3]),
        )
        let row = [
          angle * 0.1,
          angle * -0.2,
          0.8 + angle * 0.01,
          quaternion[1],
          quaternion[2],
          quaternion[3],
          quaternion[0],
        ]
        row.append(
          Array::makei(29, i => {
            if i < count {
              @math.sin(angle + i.to_double()) * 0.1
            } else {
              0.0
            }
          }),
        )
        row
      })
      let result : @aligned.MotionClip = {
        name: "clip-\{clip}",
        sha256: "synthetic-\{clip}",
        rows,
      }
      result
    })
    let original = @aligned.MotionLibrary::new(
      clips,
      { bodies: [], tracked: [], q_lo: [], q_hi: [], },
      source_fps=50.0,
      exact_control_frames=true,
      compute_body_features=false,
    )
    for heading in [false, true] {
      let motion = { ..original, orthonormal_heading: heading, }
      for preview in [1, 10] {
        let spec : @portable.Spec = {
          format: "lunakine.elu-actor.v1",
          history_frames: 1,
          observation_width: 99,
          encoder: [preview * 73, 32],
          decoder: [131, 29],
          observation_norm: {
            mean: Array::make(99, 0.0),
            variance: Array::make(99, 1.0),
            epsilon: 0.01,
          },
          goal_norm: {
            mean: Array::make(preview * 73, 0.0),
            variance: Array::make(preview * 73, 1.0),
            epsilon: 0.01,
          },
          action_mask: Array::makei(29, i => if i < count { 1.0 } else { 0.0 }),
        }
        let bundle = @deployed.Bundle::parse(Json(spec), {
          "format": "moonrobo.lunakine-e1.v1",
          "identity": { "robot": Json(robot) },
          "source_spec": {
            "format": "moonrobo.native-tensor-actor-spec.v1",
            "observation_mode": "smc",
            "hist": 1,
            "goal_frames": preview,
          },
          "physical_action_count": count,
        })
        for clip_index in 0..<2 {
          let artifact = lunakine_reference(motion, clip_index, robot, bundle)
          let clip = @reference.Clip::parse(
            bundle,
            @json.parse(artifact.stringify()),
          )
          let start = motion.clip_start[clip_index]
          let end = motion.clip_end[clip_index]
          let task : @skills.Execution = {
            request_id: "reference-test",
            sequence: 0L,
            skill_id: "software",
            reference_id: motion.names[clip_index],
            parameters: Map([]),
            state: Running,
            accepted_at_ms: 100L,
            deadline_ms: 1100L,
            detail: "synthetic",
          }
          assert_eq(clip.frame_count(), end - start + 1)
          assert_eq(clip.duration_ms(), (end - start).to_int64() * 20L)
          for step in 0..<clip.frame_count() {
            let frame = clip.frame(task, step)
            let expected = motion.goal(start + step, preview)
            assert_eq(frame.complete, step == end - start)
            assert_eq(frame.body_to_world, motion.states[start + step].rotation)
            for i in 0..<expected.length() {
              assert_true((frame.goals[i] - expected[i]).abs() < 1.0e-12)
              compared += 1
            }
            for future in 0..<preview {
              for axis in count..<29 {
                assert_eq(frame.goals[future * 73 + 15 + axis], 0.0)
                assert_eq(frame.goals[future * 73 + 44 + axis], 0.0)
              }
            }
          }
          // Preview repeats its own final state, never crosses into the next clip.
          let terminal = clip.frame(task, clip.frame_count())
          assert_true(terminal.complete)
          for future in 1..<preview {
            assert_eq(
              terminal.goals[future * 73:future * 73 + 73].to_owned(),
              terminal.goals[:73].to_owned(),
            )
          }
        }
      }
    }
  }
  assert_eq(compared, 25696)
}

///|
async test "prepared reference file conversion needs no initialized model tensor or robot SDK" {
  let directory = @fs.tmpdir(prefix="e1-reference-export")
  defer @fs.rmdir(directory, recursive=true)
  @fs.mkdir(directory + "/bundle")
  @fs.mkdir(directory + "/motions")
  let robot = profile()
  let spec : @portable.Spec = {
    format: "lunakine.elu-actor.v1",
    history_frames: 1,
    observation_width: 99,
    encoder: [146, 32],
    decoder: [131, 29],
    observation_norm: {
      mean: Array::make(99, 0.0),
      variance: Array::make(99, 1.0),
      epsilon: 0.01,
    },
    goal_norm: {
      mean: Array::make(146, 0.0),
      variance: Array::make(146, 1.0),
      epsilon: 0.01,
    },
    action_mask: Array::makei(29, i => if i < 23 { 1.0 } else { 0.0 }),
  }
  let companion : Json = {
    "format": "moonrobo.lunakine-e1.v1",
    "identity": { "robot": Json(robot) },
    "source_spec": {
      "format": "moonrobo.native-tensor-actor-spec.v1",
      "observation_mode": "smc",
      "hist": 1,
      "goal_frames": 2,
    },
    "physical_action_count": 23,
  }
  @fs.write_file(
    directory + "/bundle/actor.json",
    @utf8.encode(Json(spec).stringify()),
    create_mode=CreateNew,
  )
  @fs.write_file(
    directory + "/bundle/robot.json",
    @utf8.encode(companion.stringify()),
    create_mode=CreateNew,
  )
  let rows = Array::makei(4, step => {
    let row = [step.to_double() * 0.1, 0.0, 0.8, 0.0, 0.0, 0.0, 1.0]
    row.append(
      Array::makei(29, i => if i < 23 { step.to_double() * 0.01 } else { 0.0 }),
    )
    row
  })
  let bytes = @utf8.encode(Json(rows).stringify())
  @fs.write_file(
    directory + "/motions/prepared.json",
    bytes,
    create_mode=CreateNew,
  )
  // Only identity checks are under test: this is no executable simulator asset.
  let scene = @utf8.encode("synthetic scene identity fixture")
  @fs.write_file(directory + "/scene.xml", scene, create_mode=CreateNew)
  @fs.write_file(
    directory + "/scene.json",
    @utf8.encode("{\"meshes\":{}}"),
    create_mode=CreateNew,
  )
  let dataset : Dataset = {
    format: "moonrobo.e1-dataset.v1",
    robot,
    scene_sha256: @artifacts.sha256(scene),
    entries: [
      {
        id: "prepared",
        file: "motions/prepared.json",
        sha256: @artifacts.sha256(bytes),
        source_sha256: "synthetic-source",
        split: "validation",
        fps: 50.0,
      },
    ],
  }
  @fs.write_file(
    directory + "/dataset.json",
    @utf8.encode(Json(dataset).stringify()),
    create_mode=CreateNew,
  )
  let output = directory + "/reference.json"
  let result = export_lunakine_reference(
    directory,
    directory + "/bundle",
    "prepared",
    output,
  )
  assert_true(
    result
    is { "frames": 4, "published": False, "hardware_qualified": False, .. },
  )
  let bundle = @deployed.Bundle::read(directory + "/bundle")
  let clip = @reference.Clip::read(bundle, output)
  assert_eq(
    (clip.reference_id(), clip.frame_count(), clip.duration_ms()),
    ("prepared", 4, 60L),
  )
  let saved = @fs.read_file(output).binary()
  try
    export_lunakine_reference(
      directory,
      directory + "/bundle",
      "prepared",
      output,
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("reference export overwrote existing artifact")
  }
  assert_eq(@fs.read_file(output).binary(), saved)
  try
    export_lunakine_reference(
      directory,
      directory + "/bundle",
      "absent",
      directory + "/absent.json",
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("missing reference clip was exported")
  }
  assert_true(!@fs.exists(directory + "/absent.json"))
}
