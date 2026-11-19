///|
/// Qualify sampled BONES-SEED sessions with the same fitter and native physics
/// screen used for the E1 curriculum. Split assignment precedes fitting.
pub async fn prepare_bones_supplement(
  base : String,
  library : String,
  g1_directory : String,
  g1_scene : String,
  selection : String,
  panel : String,
  output : String,
) -> Json {
  let dataset = open_dataset(base)
  let admission = require_admission(base, dataset, library)
  let pins = @json.parse(@utf8.decode(read_bounded(selection, 4194304L)))
  let heldout = @json.parse(@utf8.decode(read_bounded(panel, 4194304L)))
  let clips : Array[Json] = json_field(pins, "clips")
  let tests : Array[Json] = json_field(heldout, "clips")
  guard !@fs.exists(output) &&
    clips.length() > 0 &&
    tests.length() == 40 &&
    (json_field(pins, "catalog_sha256") : String) ==
    hash_file(g1_directory + "/manifest.paper-partial.json") &&
    (json_field(pins, "heldout_panel_sha256") : String) == hash_file(panel) &&
    (json_field(pins, "source_fps") : Double) == 120.0 &&
    (json_field(heldout, "source_fps") : Double) == 120.0 else {
    fail("invalid BONES source, held-out panel or output")
  }
  let sessions : Set[String] = Set::new()
  let hashes : Set[String] = Set::new()
  for row in tests {
    let id : String = json_field(row, "id")
    sessions.add(id.split("/").collect()[0].to_owned())
    hashes.add(json_field(row, "sha256"))
  }
  let target_rt = @sim.Runtime::open(library, base + "/scene.xml")
  let target_kin = @tracking.kinematics(
    target_rt,
    names=dataset.robot.joints,
    tracked_names=dataset.robot.tracked,
    root_name="base_link",
  )
  let source_rt = @sim.Runtime::open(library, g1_scene)
  let source_kin = @tracking.kinematics(source_rt)
  let names = @aligned.joint_names()
  let velocity = names.map(name => @aligned.motor_of(name).velocity)
  let entries : Array[MotionEntry] = []
  let accepted : Array[Json] = []
  let rejected : Array[Json] = []
  @fs.mkdir(output + "/reports", recursive=true)
  @fs.mkdir(output + "/motions")
  for row in clips {
    let id : String = json_field(row, "id")
    let path : String = json_field(row, "path")
    let split : String = json_field(row, "split")
    let session : String = json_field(row, "session")
    let digest : String = json_field(row, "sha256")
    let raw : String = json_field(row, "source_sha256")
    guard id.split("/").collect() is [first, second] &&
      first == session &&
      first.length() > 0 &&
      second.length() > 0 &&
      !id.contains("..") &&
      !id.contains("\\") &&
      path == "clips/" + id + ".csv" &&
      ["train", "validation"].contains(split) &&
      !sessions.contains(session) &&
      !hashes.contains(digest) &&
      !hashes.contains(raw) else {
      fail("unsafe, overlapping or duplicate source " + id)
    }
    sessions.add(session)
    hashes.add(digest)
    hashes.add(raw)
    let bytes = read_bounded(g1_directory + "/" + path, 67108864L)
    guard @artifacts.sha256(bytes) == digest else {
      fail("BONES input changed " + id)
    }
    let clip : @aligned.MotionClip = {
      name: id,
      sha256: digest,
      rows: @aligned.parse_motion_csv(@utf8.decode(bytes)),
    }
    let (entry, report) = qualify_clip(
      clip,
      120.0,
      source_rt,
      source_kin,
      names,
      velocity,
      target_rt,
      target_kin,
      dataset.robot,
      "bones-" + id.replace_all(old="/", new="__"),
      split,
      output,
    )
    match entry {
      Some(e) => {
        entries.push(e)
        let path = "reports/" + e.id + ".json"
        accepted.push({
          "id": e.id,
          "sha256": e.sha256,
          "split": e.split,
          "report": path,
          "report_sha256": hash_file(output + "/" + path),
        })
      }
      None =>
        rejected.push({
          "id": (json_field(report, "id") : String),
          "source_sha256": digest,
          "split": split,
          "reasons": (json_field(json_field(report, "screen"), "reasons") : Json),
        })
    }
  }
  let result : Json = {
    "format": "moonrobo.e1-bones-supplement.v1",
    "candidate_count": clips.length(),
    "entries": entries,
    "accepted": accepted,
    "rejected": rejected,
    "generator_binary_sha256": hash_file("/proc/self/exe"),
    "selection_sha256": hash_file(selection),
    "panel_sha256": hash_file(panel),
    "model_validation_sha256": (
      json_field(admission, "model_validation_sha256") : String),
    "g1_scene_sha256": hash_file(g1_scene),
    "e1_scene_sha256": dataset.scene_sha256,
    "mujoco_sha256": hash_file(library),
    "rules": reference_rules(),
  }
  @fs.write_file(
    output + "/supplement.json",
    @utf8.encode(result.stringify(indent=2)),
    create_mode=CreateNew,
  )
  result
}
