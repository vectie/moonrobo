///|
/// Compare two recorded controllers through their last shared physical step.
pub async fn policy_tracking_study(
  dataset : String,
  library : String,
  baseline : String,
  candidate : String,
  output : String,
) -> Json {
  let robot = open_dataset(dataset).robot
  let rt = @sim.Runtime::open(library, dataset + "/scene.xml")
  let layout = @tracking.joint_layout(rt, names=robot.joints)
  let ids = robot.tracked.map(n => id_of_body(rt, n))
  let feet = [ids[3], ids[6]]
  let boxes = feet.map(i => rt.body_box(i))
  let references : Array[Array[Json]] = []
  let runs : Array[Array[Json]] = []
  let manifests : Array[Array[Json]] = []
  let actors : Array[String] = []
  let panel_sha : Array[String] = []
  for dir in [baseline, candidate] {
    let run = read_study_json(dir + "/final.json")
    let ref_doc = read_study_json(dir + "/references.json")
    let poses = read_study_json(dir + "/e1/poses.json")
    assert_eq(
      (json_field(run, "references_sha256") : String),
      hash_file(dir + "/references.json"),
    )
    assert_eq((json_field(run, "benchmark_complete") : Bool), true)
    assert_eq((json_field(ref_doc, "arm_orientation") : String), "arms-guarded")
    assert_eq(
      (json_field(ref_doc, "target_scene_sha256") : String),
      hash_file(dataset + "/scene.xml"),
    )
    assert_eq((json_field(poses, "joints") : Array[String]), robot.joints)
    assert_eq((json_field(poses, "control_hz") : Int32), 50)
    references.push(json_field(ref_doc, "clips"))
    panel_sha.push(json_field(ref_doc, "panel_sha256"))
    actors.push(json_field(run, "actor_archive_sha256"))
    runs.push(json_field(run, "per_clip"))
    manifests.push(json_field(poses, "clips"))
  }
  assert_eq(panel_sha[0], panel_sha[1])
  guard actors[0] != actors[1] &&
    [references, runs, manifests].all(pair => {
      pair.all(clips => clips.length() == 40)
    }) else {
    fail("expected two distinct actors on the full panel")
  }
  let details : Array[Json] = []
  let angles = [0.0, 0.0]
  let foot_stats = [FootStudy::new(), FootStudy::new()]
  let mut steps = 0
  for i, meta in references[0] {
    let name : String = json_field(meta, "id")
    let digest : String = json_field(meta, "reference_sha256")
    let prefix = "/" + i.to_string()
    let path = baseline + "/fitted" + prefix + ".json"
    assert_eq(digest, hash_file(path))
    let rows : Array[Array[Double]] = @json.from_json(read_study_json(path))
    let stance : Array[Array[Bool]] = @json.from_json(
      read_study_json(baseline + "/fitted" + prefix + ".stance.json"),
    )
    assert_eq(rows.length(), stance.length())
    let tracks : Array[Bytes] = []
    let mut common = rows.length() - 1
    for j, dir in [baseline, candidate] {
      let t = runs[j][i]
      let manifest = manifests[j][i]
      assert_eq(
        (json_field(references[j][i], "reference_sha256") : String),
        digest,
      )
      assert_eq((json_field(t, "clip_id") : String), name)
      assert_eq((json_field(manifest, "id") : String), name)
      let n : Int32 = json_field(t, "executed_steps")
      assert_eq((json_field(t, "expected_steps") : Int32), rows.length() - 1)
      let data = read_bounded(dir + "/e1" + prefix + ".f32", 4194304L)
      assert_eq(
        @artifacts.sha256(data),
        (json_field(manifest, "sha256") : String),
      )
      assert_eq(data.length(), (n + 1) * (7 + robot.joints.length()) * 4)
      common = common.min(n)
      tracks.push(data)
    }
    guard common > 0 else { fail("no paired physical steps for " + name) }
    steps += common
    let prev : Array[Array[SoleFrame?]] = [[None, None], [None, None]]
    let squared = [0.0, 0.0]
    for f in 0..<=common {
      set_pose(rt, layout, state_of_row(rows[f]))
      let rotations = rt.body_rotations()
      let reference = [rotations[ids[0]], rotations[ids[11]]]
      for j, data in tracks {
        set_pose(rt, layout, recorded_state(data, f, robot.joints.length()))
        let actual = rt.body_rotations()
        let soles = native_feet(rt, feet, stance[f], actual)
        if f > 0 {
          let angle = audit_angles(reference, [actual[ids[0]], actual[ids[11]]])[1]
          squared[j] += angle * angle
          for k, sole in soles {
            let (center, half) = boxes[k]
            foot_stats[j].add(sole, prev[j][k], center, half)
          }
        }
        prev[j] = soles.map(x => Some(x))
      }
    }
    let mse = squared.map(x => x / common.to_double())
    for j, x in mse {
      angles[j] += x
    }
    details.push({
      "id": name,
      "common_steps": common,
      "right_shoulder_tracking_rmse_deg": mse.map(x => {
        x.sqrt() * 180.0 / @math.PI
      }),
    })
  }
  let result : Json = {
    "panel_sha256": panel_sha[0],
    "actor_sha256": actors,
    "common_steps": steps,
    "order": ["frozen_14k", "fine_tuned"],
    "right_shoulder_tracking_rmse_deg": angles.map(x => {
      (x / 40.0).sqrt() * 180.0 / @math.PI
    }),
    "foot_stance_common": foot_stats,
    "per_clip": details,
  }
  @fs.write_file(
    output,
    @utf8.encode(result.stringify(indent=2)),
    create_mode=CreateNew,
  )
  result
}
