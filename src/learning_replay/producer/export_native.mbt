///|
fn check_layout(runtime : @physics.Runtime, layout : Json) -> Unit raise {
  let (nq, nv, na, nu) = runtime.dimensions()
  guard integer(field(layout, "nq")) == nq &&
    integer(field(layout, "nv")) == nv &&
    integer(field(layout, "na")) == na &&
    integer(field(layout, "nu")) == nu &&
    strings(field(layout, "joint_names")) == runtime.joint_names() else {
    fail("reference state layout differs from the selected MuJoCo model")
  }
  let names = strings(field(layout, "body_names"))
  guard names.length() + 1 == runtime.body_count() else {
    fail("reference body count differs")
  }
  for i, name in names {
    guard runtime.body_name(i + 1) == name else {
      fail("reference body order differs")
    }
  }
  let q = array(field(layout, "q_indices"))
  let addresses = runtime.q_indices()
  guard q.length() == addresses.length() else {
    fail("reference joint address count differs")
  }
  for i, value in q {
    guard integer(value) == addresses[i] else {
      fail("reference joint state address differs")
    }
  }
}

///|
/// Forward-only reconstruction of archived full MuJoCo states. Nothing in this
/// producer calls Runtime.step or supplies a policy; metrics remain the study's
/// original evidence. Initial and terminal states are both retained.
pub async fn export_reference_study(
  library~ : String,
  scene~ : String,
  study_path~ : String,
  references_directory~ : String,
  output_directory~ : String,
  source_directory? : String,
  seed? : Int32,
  start_step? : Int32,
  clip_ids~ : Array[String] = [],
  limit~ : Int32 = 8,
) -> Json {
  guard limit > 0 && limit <= 256 else {
    fail("replay clip limit must be 1..256")
  }
  if seed is Some(value) {
    guard value >= 0 else { fail("seed must be nonnegative") }
  }
  if start_step is Some(value) {
    guard value >= 0 else { fail("start-step must be nonnegative") }
  }
  let output_path = output_directory + "/replay.json"
  guard !@fs.exists(output_path) else {
    fail("replay output exists; choose a new output directory")
  }
  let study_bytes = @fs.read_file(study_path).binary()
  let study = @json.parse(@utf8.decode(study_bytes))
  let manifest_bytes = @fs.read_file(references_directory + "/manifest.json").binary()
  let manifest = @json.parse(@utf8.decode(manifest_bytes))
  let manifest_hash = @artifacts.sha256(manifest_bytes)
  guard text(field(study, "reference_manifest_sha256")) == manifest_hash else {
    fail("study and reference manifest SHA256 differ")
  }
  let scene_hash = @artifacts.sha256(@fs.read_file(scene).binary())
  guard text(field(manifest, "scene_sha256")) == scene_hash else {
    fail("selected scene does not match the recorded reference scene SHA256")
  }
  let runtime = @physics.Runtime::open(
    library,
    scene,
    require_position_servos=false,
  )
  guard text(field(manifest, "mujoco_version")) == runtime.version() else {
    fail("replay requires the reference's pinned MuJoCo runtime version")
  }
  let layout = field(manifest, "layout")
  check_layout(runtime, layout)
  let dt = number(field(layout, "dt_s"))
  guard dt > 0 else { fail("reference timestep must be positive") }
  let model = export_model(
    runtime,
    library,
    scene,
    output_directory + "/assets",
  )
  let metadata : Map[String, Json] = Map([])
  for clip in array(field(manifest, "clips")) {
    let id = text(field(clip, "id"))
    guard !metadata.contains(id) else { fail("duplicate reference clip ID") }
    metadata[id] = clip
  }
  let source_root = source_directory.unwrap_or(parent(study_path))
  let cached : Map[String, Array[Array[Double]]] = Map([])
  let clips : Array[@replay.Clip] = []
  let mut pose_budget = 0
  let mut frame_budget = 0
  let selected_ids : Map[String, Unit] = Map([])
  let (nq, nv, na, nu) = runtime.dimensions()
  for (record, role) in records_from_study(study, seed) {
    let id = text(field(record, "reference_id"))
    let origin = integer(field(record, "origin_step"))
    if (!clip_ids.is_empty() && !clip_ids.contains(id)) ||
      (start_step is Some(wanted) && origin != wanted) {
      continue
    }
    if clips.length() >= limit {
      break
    }
    guard metadata.get(id) is Some(reference) else {
      fail("physical record reference ID missing")
    }
    let reference_hash = text(field(reference, "sha256"))
    guard text(field(record, "reference_sha256")) == reference_hash else {
      fail("physical record points to a different reference archive")
    }
    if !cached.contains(id) {
      let file = text(field(reference, "file"))
      guard !file.has_prefix("/") else {
        fail("reference file must be relative")
      }
      let bytes = @fs.read_file(source_path(references_directory, file)).binary()
      guard @artifacts.sha256(bytes) == reference_hash else {
        fail("reference archive changed")
      }
      cached[id] = matrix(@artifacts.decode_npz(bytes), "state")
    }
    let target = cached[id]
    let record_hash = text(field(record, "sha256"))
    let bytes = @fs.read_file(
      source_path(source_root, text(field(record, "file"))),
    ).binary()
    guard @artifacts.sha256(bytes) == record_hash else {
      fail("physical archive changed")
    }
    let arrays = @artifacts.decode_npz(bytes)
    let states = matrix(arrays, "state")
    let next_states = matrix(arrays, "next_state")
    let actions = matrix(arrays, "applied_action")
    let count = integer(field(record, "steps"))
    guard count > 0 &&
      count == states.length() &&
      count == next_states.length() &&
      count == actions.length() &&
      origin < target.length() &&
      count < target.length() - origin &&
      states.all(row => row.length() == nq + nv + na) &&
      next_states.all(row => row.length() == nq + nv + na) &&
      target.all(row => row.length() == nq + nv + na) &&
      actions.all(row => row.length() == nu) else {
      fail(
        "physical and reference trajectory dimensions, phase, or frame count differ",
      )
    }
    guard arrays.get("terminated") is Some(terminated) &&
      arrays.get("truncated") is Some(truncated) &&
      terminated.shape == [count] &&
      truncated.shape == [count] &&
      terminated.values.length() == count &&
      truncated.values.length() == count &&
      terminated.values.all(x => x == 0 || x == 1) &&
      truncated.values.all(x => x == 0 || x == 1) else {
      fail("recorded trajectory needs boolean terminated/truncated arrays")
    }
    for i in 0..<(count - 1) {
      guard terminated.values[i] == 0 && truncated.values[i] == 0 else {
        fail("recorded trajectory continues after termination or truncation")
      }
    }
    let failed = terminated.values[count - 1] != 0
    let time_limit = truncated.values[count - 1] != 0
    let frames = count + 1 + target.length() - origin
    frame_budget += frames
    pose_budget += frames * runtime.body_count()
    guard frame_budget <= 200000 && pose_budget <= 2000000 else {
      fail(
        "selected trajectories exceed replay size limits; select fewer actions/origins",
      )
    }
    // A sequence must be contiguous. Historical Float32 arrays preserve the same
    // next/state row bytes; use a small explicit tolerance for JSON round trips.
    for i in 1..<count {
      for j, value in states[i] {
        guard (value - next_states[i - 1][j]).abs() <= 0.000001 else {
          fail("recorded episode is not a contiguous trajectory")
        }
      }
    }
    let actual_frames : Array[@replay.PoseFrame] = []
    runtime.set_recorded_state(states[0], actions[0])
    actual_frames.push(capture_frame(runtime, 0.0))
    for i, state in next_states {
      runtime.set_recorded_state(state, actions[i])
      actual_frames.push(capture_frame(runtime, (i + 1).to_double() * dt))
    }
    let reference_frames : Array[@replay.PoseFrame] = []
    let zero_action = Array::make(nu, 0.0)
    for i in origin..<target.length() {
      runtime.set_recorded_state(target[i], zero_action)
      reference_frames.push(
        capture_frame(runtime, (i - origin).to_double() * dt),
      )
    }
    let episode_id = text(field(record, "episode_id"))
    let origin_s = origin.to_double() * dt
    clips.push({
      id: episode_id,
      label: "\{id} · \{role} · reference \{origin_s}s",
      source_start_time_s: origin_s,
      source: {
        "record_sha256": record_hash,
        "reference_sha256": reference_hash,
        "reference_id": id,
        "origin_step": origin,
        "dt_s": dt,
        "recorded_steps": count,
        "recorded_duration_s": count.to_double() * dt,
        "reference_remaining_s": (target.length() - origin - 1).to_double() * dt,
        "terminated": failed,
        "truncated": time_limit,
        "end_reason": if failed {
          "terminated"
        } else if time_limit {
          "time_limit"
        } else {
          "recording_end"
        },
        "state_convention": "MuJoCo qpos/qvel/act; original sequence; initial and final state retained",
      },
      tracks: [
        {
          id: "physics",
          kind: "physics",
          label: "Recorded physics",
          frames: actual_frames,
        },
        {
          id: "reference",
          kind: "reference",
          label: "Reference motion",
          frames: reference_frames,
        },
      ],
    })
    selected_ids[id] = ()
  }
  guard !clips.is_empty() else {
    fail("no recorded episode matches replay selection")
  }
  for id in clip_ids {
    guard selected_ids.contains(id) else {
      fail("selected action missing or excluded by clip limit: " + id)
    }
  }
  let replay : @replay.PoseReplay = {
    format: "moonrobo.pose-replay.v1",
    model,
    clips,
    source: {
      "method": "recorded-state-mj-forward",
      "scene_sha256": scene_hash,
      "study_sha256": @artifacts.sha256(study_bytes),
      "reference_manifest_sha256": manifest_hash,
      "model_ref": field(manifest, "model_ref"),
      "mujoco_version": runtime.version(),
      "simulation_steps": 0,
      "model_sha256_semantics": "SHA256 of canonical coordinate_system/bodies/visuals descriptor; mesh bytes independently hashed",
      "frame_time_semantics": "elapsed from each physical episode origin; reference phase = source_start_time_s + time_s",
      "recording_semantics": "finite archived trajectories; shorter physical track never extends to reference duration",
      "visual_geometry_scope": "MuJoCo default visible groups 0,1,2; compiled body-local geoms and mesh vertices; material RGBA; no textures",
    },
  }
  replay.validate()
  let digest = @artifacts.save_json(output_path, replay.to_json())
  {
    "format": "moonrobo.pose-replay-export-receipt.v1",
    "file": output_path,
    "sha256": digest,
    "clips": clips.length(),
    "model_sha256": model.sha256,
    "simulation_steps": 0,
  }
}
