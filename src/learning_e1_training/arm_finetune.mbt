///|
/// Rebuild only the accepted cross-embodiment clips of a pinned curriculum.
pub async fn prepare_arm_finetune(
  base : String,
  library : String,
  lafan : String,
  bones : String,
  scene : String,
  output : String,
) -> Json {
  let parent = open_dataset(base)
  let admission = require_admission(base, parent, library)
  let records : Array[Json] = json_field(admission, "accepted")
  let staging = output + ".partial"
  guard !@fs.exists(output) && !@fs.exists(staging) else {
    fail("fresh dataset directory required")
  }
  @fs.mkdir(staging + "/meshes", recursive=true)
  @fs.mkdir(staging + "/motions")
  @fs.mkdir(staging + "/reports")
  async fn copy(path : String) -> Unit {
    @fs.write_file(
      staging + "/" + path,
      read_bounded(base + "/" + path, 134217728L),
      create_mode=CreateNew,
    )
  }
  for
    path in [
      "scene.xml", "scene.json", "model-validation.json", "NOETIX-LICENSE", "BONES-SEED-LICENSE.md",
      "LICENSE.dataset", "README.dataset.md", "source-bones-selection.json", "source-g1-manifest.json",
    ] {
    copy(path)
  }
  for path in @fs.readdir(base + "/meshes") {
    copy("meshes/" + path)
  }
  let sources : Map[String, (String, String)] = Map([])
  for
    (manifest, dir, prefix) in [
      ("source-bones-selection.json", bones, "bones-"),
      ("source-g1-manifest.json", lafan, "g1-"),
    ] {
    let catalog = @json.parse(
      @utf8.decode(read_bounded(base + "/" + manifest, 4194304L)),
    )
    let list : Array[Json] = json_field(catalog, "clips")
    for reference in list {
      let name : String = json_field(reference, "id")
      let id = prefix + name.replace_all(old="/", new="__")
      let path : String = json_field(reference, "path")
      guard !path.has_prefix("/") &&
        !path.contains("..") &&
        !sources.contains(id) else {
        fail("invalid source in " + manifest)
      }
      sources[id] = (dir + "/" + path, json_field(reference, "sha256"))
    }
  }
  let target = @sim.Runtime::open(library, staging + "/scene.xml")
  let kin = @tracking.kinematics(
    target,
    names=parent.robot.joints,
    tracked_names=parent.robot.tracked,
    root_name="base_link",
  )
  let g1 = @sim.Runtime::open(library, scene)
  let source_kin = @tracking.kinematics(g1)
  let names = @aligned.joint_names()
  let velocity = names.map(name => @aligned.motor_of(name).velocity)
  let accepted : Array[Json] = []
  let entries : Array[MotionEntry] = []
  for i, entry in parent.entries {
    let path : String = json_field(records[i], "report")
    if entry.id.has_prefix("vendor-") {
      copy(entry.file)
      copy(path)
      accepted.push(records[i])
      entries.push(entry)
      continue
    }
    guard sources.get(entry.id) is Some((file, digest)) &&
      digest == entry.source_sha256 else {
      fail("missing pinned source for " + entry.id)
    }
    let bytes = read_bounded(file, 67108864L)
    guard @artifacts.sha256(bytes) == digest else {
      fail("source changed: " + entry.id)
    }
    let old = @json.parse(
      @utf8.decode(read_bounded(base + "/" + path, 4194304L)),
    )
    guard old is { "source_start_frame": Null, .. } else {
      fail("expected a complete recording")
    }
    let clip : @aligned.MotionClip = {
      name: entry.id,
      sha256: digest,
      rows: @aligned.parse_motion_csv(@utf8.decode(bytes)),
    }
    let (fresh, report) = qualify_clip(
      clip,
      json_field(old, "source_fps"),
      g1,
      source_kin,
      names,
      velocity,
      target,
      kin,
      parent.robot,
      entry.id,
      entry.split,
      staging,
      arms=ArmsGuarded,
      expected_base_sha=entry.sha256,
    )
    guard fresh is Some(item) else {
      fail("previously admitted clip failed: " + entry.id)
    }
    for field in ["source_frames", "output_frames", "time_scale"] {
      guard (json_field(old, field) : Json) ==
        (json_field(report, field) : Json) else {
        fail("duration or tempo changed: " + entry.id)
      }
    }
    entries.push(item)
    accepted.push({
      "id": item.id,
      "sha256": item.sha256,
      "split": item.split,
      "report": path,
      "report_sha256": hash_file(staging + "/" + path),
    })
  }
  let result_dataset = { ..parent, entries, }
  let data = @utf8.encode(Json(result_dataset).stringify(indent=2))
  @fs.write_file(staging + "/dataset.json", data, create_mode=CreateNew)
  let result : Json = {
    "format": "moonrobo.e1-dataset-admission.v2",
    "passed": true,
    "dataset_sha256": @artifacts.sha256(data),
    "model_validation_sha256": hash_file(staging + "/model-validation.json"),
    "parent_dataset_sha256": hash_file(base + "/dataset.json"),
    "parent_admission_sha256": hash_file(base + "/admission.json"),
    "source_g1_scene_sha256": hash_file(scene),
    "generator_binary_sha256": hash_file("/proc/self/exe"),
    "candidate_count": entries.length(),
    "training_clips": entries.filter(e => e.split == "train").length(),
    "validation_clips": entries.filter(e => e.split == "validation").length(),
    "arm_orientation": "arms-guarded",
    "scope": "Frozen parent curriculum and splits. Native E1 clips copied unchanged. Source G1 clips require exact reproduction of the parent trajectory before arm correction.",
    "rules": reference_rules(),
    "accepted": accepted,
    "rejected": [],
  }
  @fs.write_file(
    staging + "/admission.json",
    @utf8.encode(result.stringify(indent=2)),
    create_mode=CreateNew,
  )
  ignore(require_admission(staging, result_dataset, library))
  @fs.rename(staging, output, replace=false)
  result
}
