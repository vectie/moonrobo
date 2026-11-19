///|
/// A stance sample is one source-labelled foot at a control frame. Slip is the
/// in-plane motion of the same material point between two near-contact frames.
priv struct FootStudy {
  mut samples : Int32
  mut touching : Int32
  mut near : Int32
  mut lifted : Int32
  mut peak_penetration_m : Double
  mut squared_depth : Double
  mut slip_samples : Int32
  mut slip_distance_m : Double
} derive(ToJson)

///|
fn FootStudy::new() -> FootStudy {
  {
    samples: 0,
    touching: 0,
    near: 0,
    lifted: 0,
    peak_penetration_m: 0.0,
    squared_depth: 0.0,
    slip_samples: 0,
    slip_distance_m: 0.0,
  }
}

///|
priv struct SoleFrame {
  p : Array[Double]
  r : Array[Double]
  gap : Double
  stance : Bool
}

///|
fn FootStudy::add(
  self : FootStudy,
  now : SoleFrame,
  prev : SoleFrame?,
  center : Array[Double],
  half : Array[Double],
) -> Unit {
  if !now.stance {
    return
  }
  self.samples += 1
  let depth = (-now.gap).max(0.0)
  self.peak_penetration_m = self.peak_penetration_m.max(depth)
  self.squared_depth += depth * depth
  if now.gap <= 0.0 {
    self.touching += 1
  }
  if now.gap > 0.02 {
    self.lifted += 1
  }
  if now.gap > 0.002 {
    return
  }
  self.near += 1
  guard prev is Some(last) && last.stance && last.gap <= 0.002 else { return }
  // Choose the box support point facing -Z. In a flat direction use the
  // midpoint, so an exactly level sole uses the centre of the contact face.
  let q = Array::makei(3, j => {
    let v = now.r[6 + j]
    center[j] +
    (if v.abs() < 1.0e-9 { 0.0 } else if v > 0.0 { -half[j] } else { half[j] })
  })
  let a = @aligned.vec_add(now.p, @aligned.mat_vec(now.r, q))
  let b = @aligned.vec_add(last.p, @aligned.mat_vec(last.r, q))
  let x = a[0] - b[0]
  let y = a[1] - b[1]
  self.slip_samples += 1
  self.slip_distance_m += (x * x + y * y).sqrt()
}

///|
fn native_feet(
  rt : @sim.Runtime,
  ids : Array[Int32],
  flags : Array[Bool],
  rotations : Array[Array[Double]],
) -> Array[SoleFrame] raise {
  Array::makei(2, k => {
    p: rt.body_world_pos(ids[k]),
    r: rotations[ids[k]],
    gap: rt.body_floor_distance(ids[k]),
    stance: flags[k],
  })
}

///|
async fn read_study_json(path : String) -> Json {
  @json.parse(@utf8.decode(read_bounded(path, 33554432L)))
}

///|
fn pair_depth(rt : @sim.Runtime, left : Int32, right : Int32) -> Double {
  let mut deepest = 0.0
  for c in rt.collision_contacts() {
    if (c.body_a == left && c.body_b == right) ||
      (c.body_a == right && c.body_b == left) {
      deepest = deepest.max(-c.distance)
    }
  }
  deepest
}

///|
/// Measure the 2x2 shoulder/elbow IK study. Score reference feet over every
/// frame and physical feet/shoulders over the same pre-termination frames.
pub async fn arm_ik_study(
  dataset : String,
  library : String,
  cases : String,
  baseline : String,
  geometry : String,
  panel_path : String,
  output : String,
) -> Json {
  guard !@fs.exists(output) else { fail("study report exists") }
  let modes = ["original", "shoulders", "elbows", "both", "arms-only"]
  if @fs.exists(cases + "/arms-guarded") {
    modes.push("arms-guarded")
  }
  let rig = open_dataset(dataset).robot
  let rt = @sim.Runtime::open(library, dataset + "/scene.xml")
  let collision = @sim.Runtime::open(library, dataset + "/scene.xml")
  collision.configure_collision(true)
  let layout = @tracking.joint_layout(rt, names=rig.joints)
  let ids = rig.tracked.map(n => id_of_body(rt, n))
  let feet = [ids[3], ids[6]]
  let boxes = feet.map(i => rt.body_box(i))
  let frozen = read_study_json(baseline + "/final.json")
  let frozen_refs = read_study_json(baseline + "/references.json")
  let frozen_rows : Array[Json] = json_field(frozen, "per_clip")
  let frozen_geometry = read_study_json(geometry + "/manifest.json")
  let gclips : Array[Json] = json_field(frozen_geometry, "clips")
  let pins : Array[PanelClip] = json_field(read_study_json(panel_path), "clips")
  let pinned = hash_file(panel_path)
  assert_eq(pins.length(), 40)
  assert_eq((json_field(frozen_geometry, "panel_sha256") : String), pinned)
  let refs : Array[Array[Json]] = []
  let rows : Array[Array[Json]] = []
  let runs : Array[Json] = []
  for mode in modes {
    let dir = cases + "/" + mode
    let final = read_study_json(dir + "/final.json")
    let ref = read_study_json(dir + "/references.json")
    assert_eq(
      (json_field(final, "references_sha256") : String),
      hash_file(dir + "/references.json"),
    )
    assert_eq((json_field(ref, "arm_orientation") : String), mode)
    for
      key in [
        "g1_scene_sha256", "target_scene_sha256", "panel_sha256", "source_fps", "time_scale",
        "control_hz",
      ] {
      assert_eq(
        (json_field(ref, key) : Json),
        (json_field(frozen_refs, key) : Json),
      )
    }
    for
      key in [
        "protocol", "source_checkpoint_sha256", "actor_archive_sha256", "training_dataset_sha256",
        "tensor_library_sha256", "mujoco_library_sha256",
      ] {
      assert_eq(
        (json_field(final, key) : Json),
        (json_field(frozen, key) : Json),
      )
    }
    let r : Array[Json] = json_field(final, "per_clip")
    let v : Array[Json] = json_field(ref, "clips")
    assert_eq(r.length(), 40)
    assert_eq(v.length(), 40)
    if mode == "original" {
      assert_eq(r, frozen_rows)
      assert_eq(v, (json_field(frozen_refs, "clips") : Array[Json]))
    }
    let gen : String = json_field(ref, "generator_sha256")
    if mode == "arms-only" {
      let bridge_ref = read_study_json(cases + "/bridge/references.json")
      let bridge = read_study_json(cases + "/bridge/final.json")
      assert_eq((json_field(bridge_ref, "generator_sha256") : String), gen)
      assert_eq(
        (json_field(bridge_ref, "clips") : Json),
        (json_field(frozen_refs, "clips") : Json),
      )
      assert_eq(
        (json_field(bridge, "per_clip") : Json),
        (json_field(frozen, "per_clip") : Json),
      )
      assert_eq(
        (json_field(bridge, "actor_archive_sha256") : Json),
        (json_field(frozen, "actor_archive_sha256") : Json),
      )
    } else if mode == "arms-guarded" {
      let control_ref = read_study_json(cases + "/bridge-guard/references.json")
      let control = read_study_json(cases + "/bridge-guard/final.json")
      assert_eq((json_field(control_ref, "generator_sha256") : String), gen)
      assert_eq(
        (json_field(control_ref, "arm_orientation") : String),
        "arms-only",
      )
      assert_eq((json_field(control_ref, "clips") : Array[Json]), refs[4])
      assert_eq((json_field(control, "per_clip") : Array[Json]), rows[4])
      assert_eq(
        (json_field(control, "actor_archive_sha256") : Json),
        (json_field(frozen, "actor_archive_sha256") : Json),
      )
    } else if !runs.is_empty() {
      assert_eq(gen, (json_field(runs[0], "generator_sha256") : String))
    }
    rows.push(r)
    refs.push(v)
    runs.push({
      "mode": Json(mode),
      "report_sha256": Json(hash_file(dir + "/final.json")),
      "references_sha256": Json(hash_file(dir + "/references.json")),
      "generator_sha256": Json(gen),
    })
  }
  assert_eq(
    (json_field(frozen, "mujoco_library_sha256") : String),
    hash_file(library),
  )
  assert_eq(
    (json_field(frozen_refs, "target_scene_sha256") : String),
    hash_file(dataset + "/scene.xml"),
  )
  let results : Array[Json] = []
  for i, pin in pins {
    let g = gclips[i]
    assert_eq(pin.id, (json_field(g, "id") : String))
    let mut common : Int32 = json_field(g, "steps")
    for r in rows {
      assert_eq(
        (json_field(r[i], "expected_steps") : Int32),
        pin.expected_steps,
      )
      assert_eq((json_field(r[i], "clip_id") : String), pin.id)
      common = common.min(json_field(r[i], "executed_steps"))
    }
    guard common >= 4 else { fail("too few shared frames") }
    let prefix = "/" + i.to_string()
    let raw = read_bounded(geometry + prefix + ".f32", 16777216L)
    assert_eq(@artifacts.sha256(raw), (json_field(g, "sha256") : String))
    let original_flags = hash_file(
      cases + "/original/fitted" + prefix + ".stance.json",
    )
    let original_rows : Array[Array[Double]] = @json.from_json(
      read_study_json(cases + "/original/fitted" + prefix + ".json"),
    )
    let variants : Array[Json] = []
    let contact_traces : Array[Json] = []
    let locked_screen : Json = json_field(refs[4][i], "screen")
    let initial_reasons : Array[String] = json_field(locked_screen, "reasons")
    let original_screen : Json = json_field(refs[0][i], "screen")
    let original_reasons : Array[String] = json_field(
      original_screen, "reasons",
    )
    let investigate = modes.length() > 5 &&
      initial_reasons.contains("self_collision") &&
      !original_reasons.contains("self_collision")
    for m, mode in modes {
      let dir = cases + "/" + mode
      let meta = refs[m][i]
      assert_eq((json_field(meta, "id") : String), pin.id)
      assert_eq((json_field(meta, "source_sha256") : String), pin.sha256)
      let reference_path = dir + "/fitted" + prefix + ".json"
      let refhash = hash_file(reference_path)
      assert_eq(refhash, (json_field(meta, "reference_sha256") : String))
      let reference : Array[Array[Double]] = @json.from_json(
        read_study_json(reference_path),
      )
      if mode == "arms-only" || mode == "arms-guarded" {
        assert_eq(reference.length(), original_rows.length())
        for k, row in reference {
          for j, value in row {
            if j < 7 ||
              j - 7 >= rig.joints.length() ||
              !rig.joints[j - 7].contains("_arm_") {
              assert_eq(value, original_rows[k][j])
            }
          }
        }
      }
      let mask_path = dir + "/fitted" + prefix + ".stance.json"
      assert_eq(hash_file(mask_path), original_flags)
      let mask : Array[Array[Bool]] = @json.from_json(
        read_study_json(mask_path),
      )
      assert_eq(reference.length(), pin.expected_steps + 1)
      assert_eq(mask.length(), reference.length())
      let poses = read_bounded(dir + "/e1" + prefix + ".f32", 2097152L)
      let actual_hash = @artifacts.sha256(poses)
      let run = rows[m][i]
      let executed : Int32 = json_field(run, "executed_steps")
      assert_eq(poses.length(), (executed + 1) * 120)
      if investigate &&
        (mode == "original" || mode == "arms-only" || mode == "arms-guarded") {
        let bodies : Array[String] = json_field(
          locked_screen, "maximum_self_penetration_bodies",
        )
        let left = id_of_body(collision, bodies[0])
        let right = id_of_body(collision, bodies[1])
        let ref_trace = reference.map(row => {
          set_pose(collision, layout, state_of_row(row))
          pair_depth(collision, left, right)
        })
        let physical = Array::makei(executed + 1, f => {
          set_pose(collision, layout, recorded_state(poses, f, 23))
          pair_depth(collision, left, right)
        })
        let peak_frame : Int32 = json_field(
          locked_screen, "maximum_self_penetration_frame",
        )
        if mode == "arms-only" {
          let peak : Double = json_field(
            locked_screen, "maximum_self_penetration_m",
          )
          assert_true((ref_trace[peak_frame] - peak).abs() < 1.0e-8)
        }
        contact_traces.push({
          "mode": Json(mode),
          "bodies": Json(bodies),
          "peak_frame_before_repair": peak_frame,
          "reference_m": Json(ref_trace),
          "recorded_pose_m": Json(physical),
        })
      }
      if m == 0 {
        assert_eq(actual_hash, (json_field(g, "e1_pose_sha256") : String))
      }
      let stance_ref = FootStudy::new()
      let stance_act = FootStudy::new()
      let stance_full = FootStudy::new()
      let mut prev_ref : Array[SoleFrame?] = [None, None]
      let mut prev_act : Array[SoleFrame?] = [None, None]
      let sums = [0.0, 0.0, 0.0]
      let f0 = [0.0, 0.0]
      let persistent = [true, true]
      for f, row in reference {
        set_pose(rt, layout, state_of_row(row))
        let ref_rot = rt.body_rotations()
        let ref_feet = native_feet(rt, feet, mask[f], ref_rot)
        for k, v in ref_feet {
          let (center, half) = boxes[k]
          stance_ref.add(v, prev_ref[k], center, half)
        }
        prev_ref = ref_feet.map(v => Some(v))
        if f > executed {
          continue
        }
        set_pose(rt, layout, recorded_state(poses, f, 23))
        let actual = rt.body_rotations()
        let af = native_feet(rt, feet, mask[f], actual)
        for k, v in af {
          let (center, half) = boxes[k]
          if f > 0 {
            stance_full.add(v, prev_act[k], center, half)
            if f <= common {
              stance_act.add(v, prev_act[k], center, half)
            }
          }
        }
        prev_act = af.map(v => Some(v))
        if f > common {
          continue
        }
        let source = Array::makei(14, b => {
          @aligned.quat_to_mat(
            Array::makei(4, k => recorded_value(raw, f * 224 + b * 4 + k)),
          )
        })
        let r = ids.map(j => ref_rot[j])
        let a = ids.map(j => actual[j])
        let sr = audit_angles(source, r)
        if f < 5 {
          for k, b in [9, 12] {
            let deg = sr[b] * 180.0 / @math.PI
            if f == 0 {
              f0[k] = deg
            }
            persistent[k] = persistent[k] && deg > 15.0
          }
        }
        if f > 0 {
          let ra = audit_angles(r, a)
          let sa = audit_angles(source, a)
          for k, x in [sr[11], ra[11], sa[11]] {
            sums[k] += x * x
          }
        }
      }
      let screen : Json = json_field(meta, "screen")
      variants.push({
        "mode": Json(mode),
        "reference_sha256": Json(refhash),
        "physical_sha256": Json(actual_hash),
        "normalized_return": (json_field(run, "normalized_return") : Json),
        "steps": Json(executed),
        "completed": (json_field(run, "completed_full_duration") : Json),
        "screen": (json_field(screen, "accepted") : Json),
        "reasons": (json_field(screen, "reasons") : Json),
        "reference_stance_position_max_m": (
          json_field(screen, "stance_position_max_m") : Json),
        "reference_stance_rotation_max_rad": (
          json_field(screen, "stance_rotation_max_rad") : Json),
        "elbow_zero_deg": Json(f0),
        "elbow_persistent": Json(persistent),
        "right_shoulder_mse_rad2": Json(sums.map(x => x / common.to_double())),
        "reference_feet": Json(stance_ref),
        "physical_feet": Json(stance_act),
        "whole_physical_feet": Json(stance_full),
      })
    }
    results.push({
      "id": Json(pin.id),
      "source_sha256": Json(pin.sha256),
      "expected_steps": Json(pin.expected_steps),
      "shared_steps": Json(common),
      "pair_contact_traces": Json(contact_traces),
      "stance_sha256": Json(original_flags),
      "variants": Json(variants),
    })
  }
  let result : Json = {
    "format": "moonrobo.arm-ik-study.v1",
    "panel_sha256": Json(pinned),
    "control_hz": 50,
    "source_orientation_manifest_sha256": Json(
      hash_file(geometry + "/manifest.json"),
    ),
    "actor_sha256": (json_field(frozen, "actor_archive_sha256") : Json),
    "checkpoint_sha256": (json_field(frozen, "source_checkpoint_sha256") : Json),
    "baseline_sha256": Json(hash_file(baseline + "/final.json")),
    "analyzer_sha256": Json(hash_file("/proc/self/exe")),
    "arm_residual_weight": 0.12,
    "runs": Json(runs),
    "clips": Json(results),
  }
  @fs.write_file(
    output,
    @utf8.encode(result.stringify(indent=2)),
    create_mode=CreateNew,
  )
  result
}
