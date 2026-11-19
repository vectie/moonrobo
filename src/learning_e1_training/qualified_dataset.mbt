///|
async fn qualify_clip(
  clip : @aligned.MotionClip,
  source_fps : Double,
  source_rt : @sim.Runtime,
  source_kin : @aligned.Kinematics,
  source_names : Array[String],
  source_velocity : Array[Double],
  target_rt : @sim.Runtime,
  target_kin : @aligned.Kinematics,
  robot : Profile,
  id : String,
  split : String,
  output : String,
  source_start? : Int32,
  minimum_speed~ : Double = 0.0,
  arms~ : ArmOrientation = Original,
  expected_base_sha? : String,
) -> (MotionEntry?, Json) {
  let initial = @aligned.MotionLibrary::new(
    [clip],
    source_kin,
    source_fps~,
    compute_body_features=false,
  )
  let source_layout = @tracking.joint_layout(source_rt, names=source_names)
  let mut fk_error = 0.0
  for frame in [0, initial.states.length() / 2, initial.states.length() - 1] {
    let s = initial.states[frame]
    set_pose(source_rt, source_layout, s)
    let positions = source_kin.forward(s)
    for b, spec in source_kin.tracked {
      let native_id = id_of_body(source_rt, source_kin.bodies[spec].name)
      fk_error = fk_error.max(
        distance(positions[b].p, source_rt.body_world_pos(native_id)),
      )
    }
  }
  guard fk_error < 1.0e-8 else { fail("source FK/native convention mismatch") }
  let mut ratio = 1.0
  for i in 0..<initial.states.length() {
    for j in 0..<source_names.length() {
      ratio = ratio.max(initial.states[i].qd[j].abs() / source_velocity[j])
    }
  }
  let time_scale = if ratio > 1.0 { (ratio * 1.05).min(4.0) } else { 1.0 }
  let library = @aligned.MotionLibrary::new(
    [clip],
    source_kin,
    source_fps=source_fps / time_scale,
    compute_body_features=false,
  )
  println(
    "Retarget \{id}: \{library.states.length()} frames, time scale \{time_scale}",
  )
  let (corrected, quality, screen, alignment) = fit_screened_reference(
    library,
    clip,
    source_kin,
    target_rt,
    target_kin,
    robot,
    smooth=source_start is Some(_),
    arms~,
    expected_base_sha?,
  )
  guard quality is Object(fields) else { fail("invalid fitter report") }
  ignore(fields.remove("stance_flags"))
  let dynamics : Json = if source_start is Some(_) {
    locomotion_screen(corrected, library, target_rt, target_kin, robot)
  } else {
    Json(())
  }
  let output_speed = horizontal_speed(corrected, 0, corrected.length(), 50.0)
  let accepted = output_speed >= minimum_speed &&
    (json_field(screen, "accepted") : Bool) &&
    (source_start is None || dynamics is { "accepted": True, .. })
  let data = @utf8.encode(Json(corrected).stringify())
  let digest = @artifacts.sha256(data)
  let report : Json = {
    "format": "moonrobo.e1-qualified-motion.v2",
    "id": id,
    "split": split,
    "source_sha256": clip.sha256,
    "source_fps": source_fps,
    "source_frames": clip.rows.length(),
    "output_fps": 50,
    "output_frames": corrected.length(),
    "time_scale": time_scale,
    "output_sha256": digest,
    "source_fk_native_max_m": fk_error,
    "task_floor_alignment_m": alignment,
    "fit": quality,
    "screen": screen,
    "tempo_changed": time_scale != 1.0,
    "source_start_frame": Json(source_start),
    "mean_horizontal_speed_m_s": output_speed,
    "minimum_horizontal_speed_m_s": minimum_speed,
    "local_dynamics": dynamics,
  }
  @fs.write_file(
    output + "/reports/" + id + ".json",
    @utf8.encode(report.stringify(indent=2)),
    create_mode=CreateNew,
  )
  if accepted {
    @fs.write_file(
      output + "/motions/" + id + ".json",
      data,
      create_mode=CreateNew,
    )
    (
      Some({
        id,
        file: "motions/" + id + ".json",
        sha256: digest,
        source_sha256: clip.sha256,
        split,
        fps: 50.0,
      }),
      report,
    )
  } else {
    (None, report)
  }
}

///|
fn fit_screened_reference(
  library : @aligned.MotionLibrary,
  clip : @aligned.MotionClip,
  source_kin : @aligned.Kinematics,
  target_rt : @sim.Runtime,
  target_kin : @aligned.Kinematics,
  robot : Profile,
  smooth~ : Bool,
  exact_control_frames~ : Bool = false,
  legacy_zero_bind~ : Bool = false,
  arms~ : ArmOrientation = Original,
  expected_base_sha? : String,
) -> (Array[Array[Double]], Json, Json, Double) raise {
  let fixed_legs = arms == ArmsOnly || arms == ArmsGuarded
  let primary : ArmOrientation = if fixed_legs { Original } else { arms }
  let (rough, rough_quality) = fit_trajectory(
    library,
    source_kin,
    target_kin,
    robot,
    legacy_zero_bind~,
    arms=primary,
  )
  let (_, rough_screen) = screen_reference(
    rough,
    rough_quality,
    target_kin,
    target_rt,
    robot,
    exact_control_frames~,
  )
  let alignment : Double = json_field(rough_screen, "floor_alignment_m")
  let leg_scale : Double = json_field(rough_quality, "leg_scale")
  let aligned_rows = library.states.map(s => {
    let quat = @aligned.mat_to_quat(s.rotation)
    let row = s.p.copy()
    row[2] += alignment / leg_scale
    row.append([quat[1], quat[2], quat[3], quat[0]])
    row.append(s.q)
    row
  })
  let aligned_source = @aligned.MotionLibrary::new(
    [{ ..clip, rows: aligned_rows, }],
    source_kin,
    source_fps=50.0,
    compute_body_features=false,
    exact_control_frames~,
  )
  fn solve(limit : Double?) -> (Array[Array[Double]], Json, Json) raise {
    let (rows, quality) = fit_trajectory(
      aligned_source,
      source_kin,
      target_kin,
      robot,
      collision_runtime=Some(target_rt),
      smooth~,
      legacy_zero_bind~,
      arms=primary,
      self_depth_limit?=limit,
    )
    let (corrected, screen) = screen_reference(
      rows,
      quality,
      target_kin,
      target_rt,
      robot,
      exact_control_frames~,
    )
    (corrected, quality, screen)
  }
  let first = solve(None)
  let (_, _, initial_screen) = first
  let reasons : Array[String] = json_field(initial_screen, "reasons")
  let retry = !legacy_zero_bind && reasons.contains("self_collision")
  let mut used_retry = false
  let (corrected, quality, screen) = if retry {
    // Keep accepted clips byte-identical. On a failed self-contact, backtrack
    // IK steps at the admission boundary; recheck the actual exported frames.
    let candidate = solve(Some(Self_penetration_limit_m - 1.0e-9))
    let (_, _, candidate_screen) = candidate
    let after : Array[String] = json_field(candidate_screen, "reasons")
    used_retry = !after.contains("self_collision") &&
      after.all(r => reasons.contains(r))
    if used_retry {
      candidate
    } else {
      first
    }
  } else {
    first
  }
  if expected_base_sha is Some(expected) {
    guard fixed_legs &&
      @artifacts.sha256(@utf8.encode(Json(corrected).stringify())) == expected else {
      fail(
        "pre-arm trajectory differs from the frozen training reference: " +
        clip.name,
      )
    }
  }
  fn refine(fraction : Double) -> (Array[Array[Double]], Json, Json) raise {
    let (arm_rows, arm_quality) = fit_trajectory(
      aligned_source,
      source_kin,
      target_kin,
      robot,
      collision_runtime=Some(target_rt),
      legacy_zero_bind~,
      arms=ShouldersAndElbows,
      fixed_base=corrected,
      arm_fraction=fraction,
      target_z_shift=json_field(screen, "floor_alignment_m"),
    )
    let (result, arm_screen) = screen_reference(
      arm_rows,
      arm_quality,
      target_kin,
      target_rt,
      robot,
      exact_control_frames~,
      floor_already_aligned=true,
    )
    (result, arm_quality, arm_screen)
  }
  let mut repair : Json = Json(())
  let (corrected, quality, screen) = if fixed_legs {
    let full = refine(1.0)
    let (_, _, full_screen) = full
    let before : Array[String] = json_field(screen, "reasons")
    let after : Array[String] = json_field(full_screen, "reasons")
    if arms == ArmsGuarded && after.any(r => !before.contains(r)) {
      let base_peak : Double = json_field(screen, "maximum_self_penetration_m")
      let extra_collision = !before.contains("self_collision") &&
        after.contains("self_collision")
      let pair_limits : Map[Int32, Double] = {}
      if extra_collision {
        let (initial_rows, _, _) = full
        let base_pairs = pair_peaks(
          corrected,
          target_kin,
          target_rt,
          robot,
          exact_control_frames~,
        )
        let initial_pairs = pair_peaks(
          initial_rows,
          target_kin,
          target_rt,
          robot,
          exact_control_frames~,
        )
        for pair, peak in initial_pairs {
          if peak > Self_penetration_limit_m {
            pair_limits[pair] = base_pairs.get(pair).unwrap_or(0.0)
          }
        }
        guard !pair_limits.is_empty() else {
          fail("self-contact screen and pair geometry differ")
        }
      }
      let attempts : Array[Json] = []
      let mut selected = (corrected, quality, screen)
      let mut retained = 0.0
      for fraction in [0.5, 0.25, 0.125, 0.0625, 0.03125, 0.015625] {
        let candidate = refine(fraction)
        let (trial_rows, _, result) = candidate
        let reasons : Array[String] = json_field(result, "reasons")
        let depth : Double = json_field(result, "maximum_self_penetration_m")
        let mut pairs_ok = true
        let mut excess = 0.0
        if !pair_limits.is_empty() {
          let observed = pair_peaks(
            trial_rows,
            target_kin,
            target_rt,
            robot,
            exact_control_frames~,
          )
          for pair, bound in pair_limits {
            excess = excess.max(observed.get(pair).unwrap_or(0.0) - bound)
          }
          pairs_ok = excess <= 1.0e-9
        }
        attempts.push({
          "fraction": fraction,
          "peak_m": depth,
          "pair_excess_m": excess,
          "reasons": reasons,
        })
        if pairs_ok &&
          reasons.all(r => before.contains(r)) &&
          (!extra_collision || depth <= base_peak + 1.0e-9) {
          retained = fraction
          selected = candidate
          break
        }
      }
      repair = {
        "fraction": retained,
        "initial_reasons": after,
        "initial_peak_m": (
          json_field(full_screen, "maximum_self_penetration_m") : Double),
        "baseline_peak_m": base_peak,
        "pair_count": pair_limits.length(),
        "attempts": attempts,
      }
      selected
    } else {
      full
    }
  } else {
    (corrected, quality, screen)
  }
  guard quality is Object(fields) else { fail("invalid trajectory fit report") }
  fields["source_bind"] = Json(
    if !legacy_zero_bind &&
      source_kin.bodies[source_kin.tracked[0]].name == "pelvis" {
      "g1-elbows-pi-over-two"
    } else {
      "joint-zero"
    },
  )
  fields["collision_retry"] = if retry {
    {
      "used": used_retry,
      "initial_peak_m": (
        json_field(initial_screen, "maximum_self_penetration_m") : Double),
      "initial_frame": (
        json_field(initial_screen, "maximum_self_penetration_frame") : Json),
      "initial_bodies": (
        json_field(initial_screen, "maximum_self_penetration_bodies") : Json),
    }
  } else {
    Json(())
  }
  if arms != Original {
    fields["arm_orientation"] = Json(arms.label())
  }
  if arms == ArmsGuarded {
    fields["arm_repair"] = repair
  }
  fields["arm_fidelity"] = arm_fidelity(
    aligned_source, corrected, source_kin, target_kin,
  )
  (corrected, quality, screen, alignment)
}

///|
/// Runs on the data host. Every source is accounted for, including exclusions.
/// The immutable training catalog contains only accepted, complete trajectories.
pub async fn prepare_qualified(
  base : String,
  lab_assets : String,
  library : String,
  model_validation : String,
  g1_directory : String,
  g1_scene : String,
  output : String,
  locomotion~ : Bool = false,
  moving~ : Bool = false,
) -> Json {
  guard !@fs.exists(output) else {
    fail("qualified dataset requires a fresh directory")
  }
  let dataset = open_dataset(base)
  let validation_bytes = read_bounded(model_validation, 4194304L)
  let validation = @json.parse(@utf8.decode(validation_bytes))
  guard validation is { "passed": True, .. } &&
    (json_field(validation, "target_scene_sha256") : String) ==
    dataset.scene_sha256 &&
    (json_field(validation, "mujoco_sha256") : String) == hash_file(library) else {
    fail("model/runtime not qualified for this dataset")
  }
  let vendor_status : Array[Json] = json_field(validation, "clips")
  @fs.mkdir(output + "/meshes", recursive=true)
  @fs.mkdir(output + "/motions")
  @fs.mkdir(output + "/reports")
  for name in ["scene.xml", "scene.json", "NOETIX-LICENSE"] {
    @fs.write_file(
      output + "/" + name,
      read_bounded(base + "/" + name, 4194304L),
      create_mode=CreateNew,
    )
  }
  for name in @fs.readdir(base + "/meshes") {
    @fs.write_file(
      output + "/meshes/" + name,
      read_bounded(base + "/meshes/" + name, 67108864L),
      create_mode=CreateNew,
    )
  }
  @fs.write_file(
    output + "/model-validation.json",
    validation_bytes,
    create_mode=CreateNew,
  )
  let target_rt = @sim.Runtime::open(library, output + "/scene.xml")
  let target_kin = @tracking.kinematics(
    target_rt,
    names=dataset.robot.joints,
    tracked_names=dataset.robot.tracked,
    root_name="base_link",
  )
  let g1_rt = @sim.Runtime::open(library, g1_scene)
  let g1_kin = @tracking.kinematics(g1_rt)
  let entries : Array[MotionEntry] = []
  let accepted : Array[Json] = []
  let rejected : Array[Json] = []
  async fn record(entry : MotionEntry?, report : Json) -> Unit {
    match entry {
      Some(entry) => {
        entries.push(entry)
        accepted.push({
          "id": entry.id,
          "sha256": entry.sha256,
          "split": entry.split,
          "report": "reports/" + entry.id + ".json",
          "report_sha256": hash_file(output + "/reports/" + entry.id + ".json"),
        })
      }
      None => rejected.push(report)
    }
  }
  if !locomotion {
    let vendor_rt = @sim.Runtime::open(
      library,
      lab_assets + "/robots/e1/mjcf/e1_24dof.xml",
      require_position_servos=false,
    )
    let vendor_robot = profile(joints=24)
    let vendor_kin = @tracking.kinematics(
      vendor_rt,
      names=vendor_robot.joints,
      tracked_names=vendor_robot.tracked,
      root_name="base_link",
    )
    for status in vendor_status {
      let name : String = json_field(status, "clip")
      if !(json_field(status, "passed") : Bool) {
        rejected.push({
          "id": "vendor-" + name,
          "reason": "source_record_fk_inconsistent",
          "source_validation": status,
        })
        continue
      }
      let bytes = read_bounded(
        lab_assets + "/datasets/mimic/" + name + ".npz",
        134217728L,
      )
      let (clip, fps) = vendor_motion(bytes, name, vendor_robot)
      let (entry, report) = qualify_clip(
        clip,
        fps,
        vendor_rt,
        vendor_kin,
        vendor_robot.joints,
        vendor_robot.velocity,
        target_rt,
        target_kin,
        dataset.robot,
        "vendor-" + name,
        if name == "0_boxing" {
          "train"
        } else {
          "validation"
        },
        output,
      )
      record(entry, report)
    }
  }
  let manifest_bytes = read_bounded(g1_directory + "/manifest.json", 4194304L)
  let manifest = @json.parse(@utf8.decode(manifest_bytes))
  let clips : Array[Json] = json_field(manifest, "clips")
  guard clips.length() == 40 &&
    (json_field(manifest, "source_fps") : Double) == 30.0 else {
    fail("expected pinned complete LAFAN1 G1 panel")
  }
  @fs.write_file(
    output + "/source-g1-manifest.json",
    manifest_bytes,
    create_mode=CreateNew,
  )
  for name in ["LICENSE.dataset", "README.dataset.md"] {
    @fs.write_file(
      output + "/" + name,
      read_bounded(g1_directory + "/" + name, 4194304L),
      create_mode=CreateNew,
    )
  }
  for item in clips {
    let path : String = json_field(item, "path")
    let id : String = json_field(item, "id")
    if locomotion &&
      !(id.has_prefix("walk") || id.has_prefix("run") || id.has_prefix("sprint")) {
      continue
    }
    guard !path.contains("..") && !path.has_prefix("/") else {
      fail("invalid G1 source path")
    }
    let bytes = read_bounded(g1_directory + "/" + path, 67108864L)
    let digest : String = json_field(item, "sha256")
    guard @artifacts.sha256(bytes) == digest else {
      fail("G1 source hash changed")
    }
    let clip : @aligned.MotionClip = {
      name: id,
      sha256: digest,
      rows: @aligned.parse_motion_csv(@utf8.decode(bytes)),
    }
    if locomotion {
      // Subject split precedes window selection. Reserve 3 and 4 for validation.
      let split = if id.has_suffix("subject3") || id.has_suffix("subject4") {
        "validation"
      } else {
        "train"
      }
      guard clip.rows.length() >= 241 else { fail("short locomotion source") }
      let minimum_speed = if !moving {
        0.0
      } else if id.has_prefix("sprint") {
        2.0
      } else if id.has_prefix("run") {
        1.2
      } else {
        0.3
      }
      let starts = if moving {
        moving_starts(clip.rows, minimum_speed)
      } else {
        [1, 3, 5, 7].map(part => (clip.rows.length() - 241) * part / 8)
      }
      for start in starts {
        let segment = { ..clip, rows: clip.rows[start:start + 241].to_owned(), }
        let (entry, report) = qualify_clip(
          segment,
          30.0,
          g1_rt,
          g1_kin,
          @aligned.joint_names(),
          @aligned.joint_names().map(name => @aligned.motor_of(name).velocity),
          target_rt,
          target_kin,
          dataset.robot,
          "g1-" + id + "-" + start.to_string(),
          split,
          output,
          source_start=start,
          minimum_speed~,
        )
        record(entry, report)
      }
      continue
    }
    let (entry, report) = qualify_clip(
      clip,
      30.0,
      g1_rt,
      g1_kin,
      @aligned.joint_names(),
      @aligned.joint_names().map(name => @aligned.motor_of(name).velocity),
      target_rt,
      target_kin,
      dataset.robot,
      "g1-" + id,
      "train",
      output,
    )
    record(entry, report)
  }
  let result_dataset : Dataset = { ..dataset, entries, }
  let bytes = @utf8.encode(Json(result_dataset).stringify(indent=2))
  @fs.write_file(output + "/dataset.json", bytes, create_mode=CreateNew)
  let train_count = entries.filter(e => e.split == "train").length()
  let validation_count = entries.filter(e => e.split == "validation").length()
  let passed = train_count >= 3 && validation_count >= 1
  let result : Json = {
    "format": if locomotion {
      "moonrobo.e1-locomotion-admission.v1"
    } else {
      "moonrobo.e1-dataset-admission.v2"
    },
    "passed": passed,
    "generator_binary_sha256": hash_file("/proc/self/exe"),
    "dataset_sha256": @artifacts.sha256(bytes),
    "model_validation_sha256": @artifacts.sha256(validation_bytes),
    "source_g1_manifest_sha256": @artifacts.sha256(manifest_bytes),
    "source_g1_scene_sha256": hash_file(g1_scene),
    "candidate_count": accepted.length() + rejected.length(),
    "training_clips": train_count,
    "validation_clips": validation_count,
    "accepted": accepted,
    "rejected": rejected,
    "rules": reference_rules(),
    "scope": if moving {
      "first moving 8 s window per quarter; mean horizontal speed minimum for walk/run/sprint 0.3/1.2/2.0 m/s on source and final reference; subjects 3 and 4 held out"
    } else if locomotion {
      "walking, running and sprinting; four predefined eight-second source windows per recording; subjects 3 and 4 held out before segmentation"
    } else {
      "complete 40-clip LAFAN1 G1 candidate panel plus four vendor clips; constrained E1 simulator curriculum; explicit tempo changes; not full BONES or hardware qualification"
    },
    "minimum_curriculum": { "train": 3, "validation": 1 },
    "hardware_calibrated": false,
  }
  @fs.write_file(
    output + "/admission.json",
    @utf8.encode(result.stringify(indent=2)),
    create_mode=CreateNew,
  )
  if passed {
    ignore(require_admission(output, result_dataset, library))
  }
  result
}
