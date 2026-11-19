///|
/// Evaluate the frozen G1 actor on the original references for the paired E1
/// run. Both embodiments use the same full-clip accumulator and control clock.
async fn evaluate_g1_panel(
  checkpoint : String,
  tensor_library : String,
  mujoco_library : String,
  scene : String,
  source : Array[@aligned.MotionClip],
  rate : Double,
  panel_sha : String,
  replay? : PanelReplay,
) -> Json {
  let receipt = @json.parse(
    @utf8.decode(read_bounded(checkpoint + "/receipt.json", 1048576L)),
  )
  let files : Map[String, String] = json_field(receipt, "files")
  for name in ["policy.pt", "state.json", "catalog.json"] {
    assert_eq(hash_file(checkpoint + "/" + name), files[name])
  }
  let state = @json.parse(
    @utf8.decode(read_bounded(checkpoint + "/state.json", 4194304L)),
  )
  let it : Int32 = json_field(receipt, "iteration")
  assert_eq((json_field(json_field(state, "runtime"), "iteration") : Int32), it)
  let identity = json_field(state, "identity")
  assert_eq((json_field(identity, "scene_sha256") : String), hash_file(scene))
  let catalog = @json.parse(
    @utf8.decode(read_bounded(checkpoint + "/catalog.json", 67108864L)),
  )
  let names : Array[String] = json_field(catalog, "motion_names")
  let hashes : Array[String] = json_field(catalog, "motion_sha256")
  for clip in source {
    guard !names.contains(clip.name) && !hashes.contains(clip.sha256) else {
      fail("G1 training overlap: " + clip.name)
    }
  }
  let meta : @gpu.CheckpointMetadata = json_field(state, "learner")
  let actor = @inference.Actor::load_archive(
    @tensor.Backend::open(tensor_library),
    checkpoint + "/policy.pt",
    @inference.ActorSpec::from_checkpoint(meta),
  )
  let rt = @sim.Runtime::open(mujoco_library, scene)
  let kin = @tracking.kinematics(rt)
  let motion = @aligned.MotionLibrary::new(source, kin, source_fps=rate)
  let env = @tracking.Environment::new([rt], motion, config={
    ..@tracking.EnvironmentConfig::default(),
    eval_mode: true,
    auto_reset: false,
    randomization: false,
    reset_noise: false,
  })
  let result = actor.evaluate(
    motion,
    {
      eval_mode: true,
      auto_reset: false,
      timeout_disabled: true,
      observation_noise: false,
      domain_randomization: false,
      simulated_replica_count: 1,
    },
    frame => env.reset(frames=[frame]),
    () => env.inspect()[0],
    action => {
      let tr = env.step([action])[0]
      if replay is Some(writer) {
        writer.capture(tr, motion)
        writer.capture_workflow(tr, motion, kin, () => env.inspect()[0].state)
      }
      tr
    },
    strict_kin=kin,
  )
  let report = result.report_json(motion.names, {
    "robot": "unitree-g1",
    "backend": "native-mujoco",
  })
  guard report is Object(fields) else { fail("invalid G1 report") }
  fields["panel_sha256"] = Json(panel_sha)
  fields["iteration"] = Json(it)
  fields["actor_archive_sha256"] = Json(files["policy.pt"])
  fields["training_catalog_sha256"] = Json(files["catalog.json"])
  fields["mujoco_library_sha256"] = Json(hash_file(mujoco_library))
  fields["tensor_library_sha256"] = Json(hash_file(tensor_library))
  fields["scene_sha256"] = Json(hash_file(scene))
  report
}
