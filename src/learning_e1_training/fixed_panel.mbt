///|
priv struct PanelClip {
  id : String
  sha256 : String
  catalog_index : Int32
  expected_steps : Int32
} derive(FromJson)

///|
/// Simulate every pinned reference, including candidates outside the E1
/// training curriculum. The geometric screen is reported for each rollout.
/// Candidate references are never written to a training catalog.
pub async fn benchmark_panel(
  dataset_directory : String,
  tensor_library : String,
  mujoco_library : String,
  g1_scene : String,
  csv_directory : String,
  panel_path : String,
  actor_directory : String,
  output : String,
  comparison_actor? : String,
  trace_indices? : Array[Int32],
  legacy_zero_bind~ : Bool = false,
  g1_checkpoint? : String,
  record_poses~ : Bool = false,
  record_workflow~ : Bool = false,
  arms~ : ArmOrientation = Original,
  record_references~ : Bool = false,
  external_holdout~ : Bool = false,
) -> Json {
  guard !record_workflow || record_poses else {
    fail("workflow capture requires paired pose recording")
  }
  guard !record_poses ||
    (
      g1_checkpoint is Some(_) &&
      comparison_actor is None &&
      trace_indices is None
    ) else {
    fail("paired recording requires both policies and the full panel")
  }
  let original = open_dataset(dataset_directory)
  ignore(require_admission(dataset_directory, original, mujoco_library))
  let panel_bytes = read_bounded(panel_path, 1048576L)
  let panel = @json.parse(@utf8.decode(panel_bytes))
  let pins : Array[PanelClip] = json_field(panel, "clips")
  let rate : Double = json_field(panel, "source_fps")
  if trace_indices is Some(indices) {
    guard comparison_actor is Some(_) &&
      !indices.is_empty() &&
      indices.all(i => i >= 0 && i < pins.length()) else {
      fail("trace-panel requires comparison actor and valid clip indices")
    }
  }
  let valid_rate = if g1_checkpoint is Some(_) || external_holdout {
    rate >= 1.0 && rate <= 500.0
  } else {
    rate == 120.0
  }
  let valid_count = if external_holdout {
    pins.length() > 0 && pins.length() <= 40
  } else {
    pins.length() == 40
  }
  guard valid_count && valid_rate && !@fs.exists(output) else {
    fail("invalid panel size, source rate or existing output directory")
  }
  let source_rt = @sim.Runtime::open(mujoco_library, g1_scene)
  let source_kin = @tracking.kinematics(source_rt)
  let rt = @sim.Runtime::open(mujoco_library, dataset_directory + "/scene.xml")
  let robot = original.robot
  let kin = @tracking.kinematics(
    rt,
    names=robot.joints,
    tracked_names=robot.tracked,
    root_name="base_link",
  )
  let source_layout = @tracking.joint_layout(
    source_rt,
    names=@aligned.joint_names(),
  )
  let clips : Array[@aligned.MotionClip] = []
  let g1_clips : Array[@aligned.MotionClip] = []
  let reports : Array[Json] = []
  let seen : Map[String, Bool] = {}
  let seen_indices : Map[Int32, Bool] = {}
  @fs.mkdir(output, recursive=true)
  if record_references {
    @fs.mkdir(output + "/fitted")
  }
  for pin in pins {
    guard !pin.id.has_prefix("/") &&
      !pin.id.contains("..") &&
      !seen.contains(pin.id) &&
      pin.catalog_index >= 0 &&
      !seen_indices.contains(pin.catalog_index) &&
      pin.expected_steps > 0 &&
      pin.expected_steps <= 10000 else {
      fail("duplicate or invalid source in fixed panel")
    }
    seen[pin.id] = true
    seen_indices[pin.catalog_index] = true
    let data = read_bounded(csv_directory + "/" + pin.id + ".csv", 67108864L)
    guard @artifacts.sha256(data) == pin.sha256 else {
      fail("G1 CSV digest differs: " + pin.id)
    }
    let clip : @aligned.MotionClip = {
      name: pin.id,
      sha256: pin.sha256,
      rows: @aligned.parse_motion_csv(@utf8.decode(data)),
    }
    if g1_checkpoint is Some(_) || external_holdout {
      guard !original.entries.any(e => {
        e.source_sha256 == pin.sha256 || e.id == pin.id
      }) else {
        fail("E1 training overlap: " + pin.id)
      }
      if g1_checkpoint is Some(_) {
        g1_clips.push(clip)
      }
    }
    let source = @aligned.MotionLibrary::new(
      [clip],
      source_kin,
      source_fps=rate,
      compute_body_features=false,
    )
    guard source.states.length() == pin.expected_steps + 1 else {
      fail("G1 panel duration differs: " + pin.id)
    }
    for i in [0, pin.expected_steps / 2, pin.expected_steps] {
      let state = source.states[i]
      set_pose(source_rt, source_layout, state)
      let bodies = source_kin.forward(state)
      for b, spec in source_kin.tracked {
        let id = id_of_body(source_rt, source_kin.bodies[spec].name)
        guard distance(bodies[b].p, source_rt.body_world_pos(id)) < 1.0e-8 else {
          fail("G1 FK/native convention mismatch: " + pin.id)
        }
      }
    }
    let (rows, quality, screen, alignment) = fit_screened_reference(
      source,
      clip,
      source_kin,
      rt,
      kin,
      robot,
      smooth=false,
      exact_control_frames=true,
      legacy_zero_bind~,
      arms~,
    )
    guard rows.length() == source.states.length() else {
      fail("retarget changed duration")
    }
    let target_hash = @artifacts.sha256(@utf8.encode(Json(rows).stringify()))
    if record_references {
      let prefix = output + "/fitted/" + clips.length().to_string()
      @fs.write_file(
        prefix + ".json",
        @utf8.encode(Json(rows).stringify()),
        create_mode=CreateNew,
      )
      @fs.write_file(
        prefix + ".stance.json",
        @utf8.encode((json_field(quality, "stance_flags") : Json).stringify()),
        create_mode=CreateNew,
      )
    }
    clips.push({ name: pin.id, sha256: target_hash, rows, })
    let record : Json = {
      "id": pin.id,
      "source_sha256": pin.sha256,
      "reference_sha256": target_hash,
      "catalog_index": pin.catalog_index,
      "expected_steps": pin.expected_steps,
      "source_in_e1_training_catalog": original.entries.any(e => {
        e.source_sha256 == pin.sha256
      }),
      "first_floor_alignment_m": alignment,
      "screen": screen,
      "source_bind": (json_field(quality, "source_bind") : String),
      "collision_retry": (json_field(quality, "collision_retry") : Json),
      "arm_fidelity": (json_field(quality, "arm_fidelity") : Json),
    }
    if arms == ArmsGuarded && record is Object(fields) {
      fields["arm_repair"] = (json_field(quality, "arm_repair") : Json)
    }
    reports.push(record)
    println("Retargeted \{clips.length()}/\{pins.length()}: \{pin.id}")
  }
  let reference_report : Json = {
    "format": "moonrobo.e1-fixed-panel-references.v1",
    "arm_orientation": Json(arms.label()),
    "panel_sha256": @artifacts.sha256(panel_bytes),
    "g1_scene_sha256": hash_file(g1_scene),
    "target_scene_sha256": original.scene_sha256,
    "generator_sha256": hash_file("/proc/self/exe"),
    "source_fps": rate,
    "control_hz": 50,
    "time_scale": 1,
    "clips": reports,
  }
  @fs.write_file(
    output + "/references.json",
    @utf8.encode(reference_report.stringify(indent=2)),
    create_mode=CreateNew,
  )
  let motion = @aligned.MotionLibrary::new(
    clips,
    kin,
    source_fps=50.0,
    exact_control_frames=true,
  )
  let actors = [("final", actor_directory)]
  if comparison_actor is Some(path) {
    actors.push(("comparison", path))
  }
  for (label, path) in actors {
    let (actor, metadata) = load_actor(path, tensor_library)
    guard metadata.identity.dataset_sha256 ==
      hash_file(dataset_directory + "/dataset.json") &&
      metadata.identity.admission_sha256 ==
      Some(hash_file(dataset_directory + "/admission.json")) &&
      Json(metadata.identity.robot) == Json(robot) &&
      metadata.identity.scene_receipt_sha256 ==
      hash_file(dataset_directory + "/scene.json") &&
      metadata.identity.tensor_library_sha256 == hash_file(tensor_library) &&
      metadata.identity.mujoco_library_sha256 == hash_file(mujoco_library) else {
      fail("frozen E1 actor, training data or runtime identity differs")
    }
    let evaluation_rt = @sim.Runtime::open(
      mujoco_library,
      dataset_directory + "/scene.xml",
    )
    let replay : PanelReplay? = if record_poses {
      Some({
        joints: robot.joints,
        tracks: {},
        workflow: if record_workflow {
          Some(Map([]))
        } else {
          None
        },
      })
    } else {
      None
    }
    let result = evaluate_motion(
      actor,
      evaluation_rt,
      kin,
      robot,
      motion,
      if g1_checkpoint is Some(_) || external_holdout {
        "paired-external-panel"
      } else {
        "external-bones-panel"
      },
      clip_indices?=trace_indices,
      replay?,
    )
    guard result is Object(fields) else { fail("invalid E1 panel report") }
    if replay is Some(writer) {
      writer.save(output + "/e1", result)
    }
    fields["actor_archive_sha256"] = Json(metadata.archive_sha256)
    fields["source_checkpoint_sha256"] = Json(metadata.source_checkpoint_sha256)
    fields["training_dataset_sha256"] = Json(metadata.identity.dataset_sha256)
    fields["tensor_library_sha256"] = Json(
      metadata.identity.tensor_library_sha256,
    )
    fields["mujoco_library_sha256"] = Json(
      metadata.identity.mujoco_library_sha256,
    )
    fields["references_sha256"] = Json(hash_file(output + "/references.json"))
    @fs.write_file(
      output + "/" + label + ".json",
      @utf8.encode(result.stringify(indent=2)),
      create_mode=CreateNew,
    )
  }
  if g1_checkpoint is Some(checkpoint) {
    let replay : PanelReplay? = if record_poses {
      Some({
        joints: @aligned.joint_names(),
        tracks: {},
        workflow: if record_workflow {
          Some(Map([]))
        } else {
          None
        },
      })
    } else {
      None
    }
    let g1 = evaluate_g1_panel(
      checkpoint,
      tensor_library,
      mujoco_library,
      g1_scene,
      g1_clips,
      rate,
      @artifacts.sha256(panel_bytes),
      replay?,
    )
    if replay is Some(writer) {
      writer.save(output + "/g1", g1)
    }
    @fs.write_file(
      output + "/g1.json",
      @utf8.encode(g1.stringify(indent=2)),
      create_mode=CreateNew,
    )
  }
  if trace_indices is Some(indices) && comparison_actor is Some(other) {
    let (primary, primary_meta) = load_actor(actor_directory, tensor_library)
    let (comparison, comparison_meta) = load_actor(other, tensor_library)
    run_panel_traces(
      rt, kin, robot, motion, indices, primary, primary_meta, comparison, comparison_meta,
      output,
    )
  }
  reference_report
}
