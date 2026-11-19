///|
fn required(value : Json, name : String) -> Json raise {
  guard value is Object(fields) && fields.get(name) is Some(result) else {
    fail("missing filter field: " + name)
  }
  result
}

///|
fn string(value : Json) -> String raise {
  guard value is String(s) else { fail("expected filter string") }
  s
}

///|
fn integer(value : Json) -> Int32 raise {
  guard value is Number(n, ..) &&
    n >= 0.0 &&
    n < 2147483648.0 &&
    n == n.to_int().to_double() else {
    fail("expected nonnegative Int32 filter count")
  }
  n.to_int()
}

///|
fn exact_count(value : Int64) -> Json raise {
  guard value >= 0L && value <= 9007199254740991L else {
    fail("filter count exceeds exact JSON integer range")
  }
  Json::number(value.to_double(), repr=value.to_string())
}

///|
fn sha256(bytes : Bytes) -> String {
  @crypto.bytes_to_hex_string(@crypto.sha256(bytes))
}

///|
async fn file_sha256(path : String) -> String {
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  let hash = @crypto.SHA256::new()
  let size = file.size()
  for offset = 0L; offset < size; {
    let n = (size - offset).min(65536L).to_int()
    hash.update(file.read_exactly_at(n, position=offset))
    continue offset + n.to_int64()
  }
  @crypto.bytes_to_hex_string(hash.finalize())
}

///|
async fn require_file_size(path : String, maximum : Int64) -> Unit {
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  guard file.size() <= maximum else {
    fail("BONES-SEED filter input exceeds per-file memory limit: " + path)
  }
}

///|
fn parent(path : String) -> String {
  let parts = path.split("/").to_array()
  let dirs : Array[String] = []
  for i in 0..<(parts.length() - 1) {
    dirs.push(parts[i].to_owned())
  }
  let result = dirs.join("/")
  if result == "" {
    "."
  } else {
    result
  }
}

///|
/// Pins the MJCF includes and meshes beside the scene as well as the entry XML.
/// Keep this byte-for-byte aligned with the native CUDA runner's tree digest.
async fn scene_assets_hash(root : String) -> String {
  let pending = [""]
  let hash = @crypto.SHA256::new()
  let mut count = 0
  let mut bytes = 0L
  while !pending.is_empty() {
    let relative = pending.pop().unwrap()
    let path = if relative == "" { root } else { root + "/" + relative }
    match @fs.kind(path, follow_symlink=false) {
      Directory => {
        let names = @fs.readdir(path, sort=true)
        guard names.length() <= 8192 &&
          pending.length() + names.length() <= 8192 else {
          fail("scene asset tree exceeds bounded metadata limit")
        }
        for name in names.rev() {
          pending.push(
            if relative == "" {
              name
            } else {
              relative + "/" + name
            },
          )
        }
      }
      Regular => {
        count += 1
        let file = @fs.open(path, mode=ReadOnly)
        bytes += file.size()
        file.close()
        guard count <= 8192 && bytes <= 17179869184L else {
          fail("scene asset tree exceeds 8192 files / 16 GiB")
        }
        hash.update(
          @utf8.encode(
            "\{relative.length()}:" + relative + ":" + file_sha256(path) + "\n",
          ),
        )
      }
      _ =>
        fail("scene asset tree contains a symlink or unsupported file: " + path)
    }
  }
  guard count > 0 else { fail("scene asset tree is empty") }
  @crypto.bytes_to_hex_string(hash.finalize())
}

///|
fn safe_relative(path : String) -> Bool {
  !path.has_prefix("/") &&
  path.split("/").all(part => part != "" && part != "." && part != "..")
}

///|
fn name_matches(id : String, terms : Array[String]) -> Bool {
  let lowered = id.to_lower()
  terms.any(term => lowered.contains(term))
}

///|
fn decision_path(root : String, index : Int32) -> String {
  root + "/" + (index / 1000).to_string() + "/" + index.to_string() + ".json"
}

///|
async fn save_json(path : String, value : Json) -> Unit {
  let temporary = path + ".partial"
  @fs.write_file(
    temporary,
    value.stringify(indent=2) + "\n",
    create_mode=CreateOrTruncate,
    permission=0o600,
    sync=Full,
  )
  @fs.rename(temporary, path, replace=true)
}

///|
fn check_config(config : Json) -> Array[String] raise {
  guard required(config, "format") ==
    Json("moonrobo.bones-seed-partial-filter-config.v1") &&
    required(config, "name_exclusion_terms") is Array(terms) else {
    fail("unsupported BONES-SEED filter config")
  }
  let normalized : Array[String] = []
  let seen : Map[String, Bool] = Map([])
  for term in terms {
    let word = string(term).trim().to_owned().to_lower()
    guard word != "" && !seen.contains(word) else {
      fail("empty or duplicate name exclusion term")
    }
    normalized.push(word)
    seen[word] = true
  }
  normalized
}

///|
fn evaluated_reasons(
  motion : @aligned.MotionLibrary,
  runtime : @mujoco.Runtime,
  layout : @aligned.JointLayout,
  body_ids : Array[Int32],
  start : Int32,
  end : Int32,
) -> Array[String] raise {
  let reasons : Array[String] = []
  let frames = end - start + 1
  guard start >= 0 && end >= start && end < motion.states.length() else {
    fail("invalid 50 Hz clip frame range")
  }
  let mut elevated_run = 0
  let mut elevated = false
  let mut deep_penetration = false
  let mut shallow_penetration = 0
  let controls = Array::make(29, 0.0)
  for frame in start..<=end {
    let state = motion.states[frame]
    runtime.set_recorded_state(
      @aligned.mujoco_state(@aligned.flatten_state(state), layout),
      controls,
    )
    let mut minimum = runtime.body_world_pos(body_ids[0])[2]
    for body_id in body_ids {
      let body = runtime.body_world_pos(body_id)
      guard body.length() == 3 && !body[2].is_nan() && !body[2].is_inf() else {
        fail("nonfinite MuJoCo body height")
      }
      minimum = minimum.min(body[2])
    }
    if minimum > 0.20 {
      elevated_run += 1
      if elevated_run >= 30 {
        elevated = true
      }
    } else {
      elevated_run = 0
    }
    if minimum < -0.12 {
      deep_penetration = true
    }
    if minimum < -0.08 {
      shallow_penetration += 1
    }
  }
  if elevated {
    reasons.push("elevated_link_30_consecutive_50hz_frames")
  }
  if deep_penetration {
    reasons.push("link_height_below_minus_0_12_m")
  }
  if shallow_penetration.to_double() / frames.to_double() > 0.80 {
    reasons.push("link_height_below_minus_0_08_m_more_than_80_percent")
  }
  reasons
}

///|
async fn main {
  let args = @env.args()
  guard args.length() == 6 else {
    fail(
      "usage: filter_bones_seed_g1.mbtx UNFILTERED_MANIFEST LIBMUJOCO SCENE_MJCF CACHE_DIR FILTER_CONFIG",
    )
  }
  let source_manifest = args[1]
  let library = args[2]
  let scene = args[3]
  let cache = args[4]
  let config_path = args[5]
  let catalog_root = parent(source_manifest)
  let output_manifest = catalog_root + "/manifest.paper-partial.json"
  let decisions_root = catalog_root + "/paper-partial-decisions-v1"
  require_file_size(source_manifest, 536870912L)
  let source_bytes = @fs.read_file(source_manifest).binary()
  let source_hash = sha256(source_bytes)
  let source : Json = @json.parse(@utf8.decode(source_bytes))
  guard source is Object(source_fields) &&
    required(source, "format") == Json("moonrobo.aligned-motion-catalog.v1") &&
    required(source, "source_repository") ==
    Json("https://huggingface.co/datasets/bones-studio/seed") &&
    required(source, "source_fps") == Json(120.0) &&
    required(source, "full_source_release") == Json(true) &&
    required(source, "clip_count") == Json(142220) &&
    required(source, "filter_status") ==
    Json(
      "unfiltered BONES-SEED G1 release; paper Appendix E filters are not yet applied",
    ) &&
    required(source, "clips") is Array(clips) &&
    clips.length() == 142220 else {
    fail("expected complete unfiltered BONES-SEED G1 source manifest")
  }
  require_file_size(config_path, 1048576L)
  let config_bytes = @fs.read_file(config_path).binary()
  let config : Json = @json.parse(@utf8.decode(config_bytes))
  let terms = check_config(config)
  let config_hash = sha256(config_bytes)
  let archive_hash = string(
    required(required(source, "acquisition"), "g1_archive_sha256"),
  )
  let archive_path = @env.get_env_var("MOONROBO_BONES_ARCHIVE").unwrap_or(
    parent(catalog_root) + "/g1.tar.gz",
  )
  guard archive_hash.length() == 64 &&
    @fs.exists(archive_path) &&
    file_sha256(archive_path) == archive_hash else {
    fail(
      "original BONES-SEED G1 archive is missing or changed; set MOONROBO_BONES_ARCHIVE",
    )
  }
  guard @fs.exists(scene) && @fs.exists(library) else {
    fail("real MuJoCo library and compiled G1 scene are required")
  }
  let scene_hash = file_sha256(scene)
  let scene_assets_sha256 = scene_assets_hash(parent(scene))
  let library_hash = file_sha256(library)
  let runtime = @mujoco.Runtime::open(
    library,
    scene,
    require_position_servos=false,
  )
  let (nq, nv, _, nu) = runtime.dimensions()
  guard nq == 36 && nv == 35 && nu == 29 else {
    fail("filter needs a real compiled free-root 29-DoF G1 MuJoCo model")
  }
  let kin = @physics.kinematics(runtime)
  let layout = @physics.joint_layout(runtime)
  let body_ids : Array[Int32] = []
  let connected : Map[Int32, Bool] = Map([])
  for body in 1..<runtime.body_count() {
    if runtime.body_name(body) == "pelvis" ||
      connected.contains(runtime.body_parent(body)) {
      body_ids.push(body)
      connected[body] = true
    }
  }
  guard !body_ids.is_empty() && body_ids.length() == kin.bodies.length() else {
    fail("cannot identify all compiled G1 robot links")
  }
  if !@fs.exists(decisions_root) {
    @fs.mkdir(decisions_root, recursive=true)
  }
  if !@fs.exists(cache) {
    @fs.mkdir(cache, recursive=true)
  }
  // The shard constructor parses one CSV at a time. Reject oversized files
  // before it starts so a malformed catalog cannot force an unbounded read.
  for clip in clips {
    let relative = string(required(clip, "path"))
    guard safe_relative(relative) && relative.has_prefix("clips/") else {
      fail("unsafe source catalog clip path")
    }
    require_file_size(catalog_root + "/" + relative, 134217728L)
  }
  // The native loader stages one source clip at a time into persistent fixed-
  // window shards, then retains a single reader for the whole 50 Hz catalog.
  let motion = @aligned.load_motion_manifest(
      source_manifest,
      kin,
      storage="mmap",
      cache_dir=cache,
      compute_body_features=false,
      max_gather_frames=1,
    ).motion
  guard motion.names.length() == clips.length() else {
    fail("source training split must contain every unfiltered clip")
  }
  let accepted_clips : Array[Json] = []
  let accepted_ids : Array[Json] = []
  let rejected : Array[Json] = []
  let mut accepted_frames = 0L
  let mut accepted_source_bytes = 0L
  let mut accepted_converted_bytes = 0L
  let ids : Map[String, Bool] = Map([])
  for index, clip in clips {
    let id = string(required(clip, "id"))
    guard motion.names[index] == id else {
      fail("source training split order differs from manifest clip order")
    }
    let relative = string(required(clip, "path"))
    let expected_hash = string(required(clip, "sha256"))
    let expected_source_hash = string(required(clip, "source_sha256"))
    guard !ids.contains(id) &&
      safe_relative(relative) &&
      relative.has_prefix("clips/") &&
      expected_hash.length() == 64 &&
      expected_source_hash.length() == 64 else {
      fail("unsafe or duplicate source catalog clip: " + id)
    }
    ids[id] = true
    let path = catalog_root + "/" + relative
    guard file_sha256(path) == expected_hash else {
      fail("converted motion hash changed: " + id)
    }
    let folder = decisions_root + "/" + (index / 1000).to_string()
    if !@fs.exists(folder) {
      @fs.mkdir(folder, recursive=true)
    }
    let receipt_path = decision_path(decisions_root, index)
    let receipt = if @fs.exists(receipt_path) {
      require_file_size(receipt_path, 65536L)
      let saved = @json.parse(@fs.read_file(receipt_path).text())
      if saved is Object(fields) &&
        fields.get("version") ==
        Some(Json("moonrobo.bones-seed-partial-decision.v1")) &&
        fields.get("id") == Some(Json(id)) &&
        fields.get("source_manifest_sha256") == Some(Json(source_hash)) &&
        fields.get("config_sha256") == Some(Json(config_hash)) &&
        fields.get("scene_sha256") == Some(Json(scene_hash)) &&
        fields.get("scene_assets_sha256") == Some(Json(scene_assets_sha256)) &&
        fields.get("library_sha256") == Some(Json(library_hash)) &&
        fields.get("g1_archive_sha256") == Some(Json(archive_hash)) &&
        fields.get("clip_sha256") == Some(Json(expected_hash)) &&
        fields.get("source_clip_sha256") == Some(Json(expected_source_hash)) {
        saved
      } else {
        fail("stale or invalid filter receipt: " + receipt_path)
      }
    } else {
      let reasons = if name_matches(id, terms) {
        ["configured_name_exclusion"]
      } else {
        evaluated_reasons(
          motion,
          runtime,
          layout,
          body_ids,
          motion.clip_start[index],
          motion.clip_end[index],
        )
      }
      let value : Json = {
        "version": "moonrobo.bones-seed-partial-decision.v1",
        "id": Json(id),
        "clip_sha256": Json(expected_hash),
        "source_clip_sha256": Json(expected_source_hash),
        "source_manifest_sha256": Json(source_hash),
        "config_sha256": Json(config_hash),
        "scene_sha256": Json(scene_hash),
        "scene_assets_sha256": Json(scene_assets_sha256),
        "library_sha256": Json(library_hash),
        "g1_archive_sha256": Json(archive_hash),
        "accepted": Json(reasons.is_empty()),
        "reasons": Json(reasons),
      }
      save_json(receipt_path, value)
      value
    }
    guard required(receipt, "reasons") is Array(reasons) &&
      required(receipt, "accepted") == Json(reasons.is_empty()) else {
      fail("invalid filter receipt decision: " + id)
    }
    if reasons.is_empty() {
      accepted_clips.push(clip)
      accepted_ids.push(Json(id))
      accepted_frames += integer(required(clip, "source_frames")).to_int64()
      accepted_source_bytes += integer(required(clip, "source_bytes")).to_int64()
      accepted_converted_bytes += integer(required(clip, "bytes")).to_int64()
    } else {
      rejected.push({ "id": Json(id), "reasons": Json(reasons) })
    }
    if (index + 1) % 1000 == 0 {
      println(
        "BONES-SEED partial filter: \{index + 1}/\{clips.length()} examined",
      )
    }
  }
  source_fields["clips"] = Json(accepted_clips)
  source_fields["clip_count"] = Json(accepted_clips.length())
  source_fields["splits"] = {
    "train": Json(accepted_ids),
    "evaluation": Json(accepted_ids),
  }
  source_fields["source_frames"] = exact_count(accepted_frames)
  source_fields["source_bytes"] = exact_count(accepted_source_bytes)
  source_fields["converted_bytes"] = exact_count(accepted_converted_bytes)
  source_fields["full_source_release"] = Json(false)
  source_fields["paper_exact_motion_set"] = Json(false)
  source_fields["filter_status"] = Json(
    "partial published BONES-SEED feasibility rules; author name list and floating-feet gates unavailable; not paper-exact",
  )
  source_fields["filter_provenance"] = {
    "version": "moonrobo.bones-seed-partial-filter.v1",
    "source_manifest_name": Json(
      source_manifest.split("/").last().unwrap().to_owned(),
    ),
    "source_manifest_sha256": Json(source_hash),
    "config_sha256": Json(config_hash),
    "config": config,
    "scene_sha256": Json(scene_hash),
    "scene_assets_sha256": Json(scene_assets_sha256),
    "mujoco_library_sha256": Json(library_hash),
    "g1_archive_sha256": Json(archive_hash),
    "mujoco_version": Json(runtime.version()),
    "sampling_hz": 50,
    "minimum_link_height": "minimum MuJoCo body origin z, excluding world, after mj_forward",
    "floor_z_m": 0.0,
    "elevated_rule": "z_min > 0.20 m for >=30 consecutive 50 Hz samples",
    "penetration_rule": "z_min < -0.12 m at any sample, or z_min < -0.08 m at >80% of samples",
    "floating_feet_rule_applied": false,
    "paper_name_list_verified": false,
    "paper_exact_motion_set": false,
    "source_clip_count": Json(clips.length()),
    "accepted_count": Json(accepted_clips.length()),
    "rejected_count": Json(rejected.length()),
    "rejections": Json(rejected),
  }
  guard file_sha256(source_manifest) == source_hash &&
    file_sha256(config_path) == config_hash &&
    file_sha256(scene) == scene_hash &&
    scene_assets_hash(parent(scene)) == scene_assets_sha256 &&
    file_sha256(library) == library_hash else {
    fail("filter inputs changed while decisions were being produced")
  }
  save_json(output_manifest, Json(source_fields))
  println("Partial BONES-SEED manifest: " + output_manifest)
  println(
    "Accepted " +
    accepted_clips.length().to_string() +
    ", rejected " +
    rejected.length().to_string(),
  )
}
