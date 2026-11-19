///|
/// Independent actor-update state verification for native final-route artifacts; does not assert a complete alternation-worker restart.
pub async fn verify_actor_update_states(
  study : String,
  library : String,
  scene : String,
) -> Json {
  let study = @fs.realpath(study)
  let report = @artifacts.load_json(study + "/report.json")
  let manifest = @artifacts.load_json(
    text(report, "references") + "/manifest.json",
  )
  verify_hash(scene, text(manifest, "scene_sha256"))
  let runtime = @native_physics.Runtime::open(library, scene)
  guard runtime.version() == text(manifest, "mujoco_version") else {
    fail("physics scene/version differs from frozen reference source")
  }
  let checks : Array[Json] = []
  for result in array(report, "runs") {
    if text(result, "gradient_route") != "stop-policy-inputs" {
      continue
    }
    let artifact = field(result, "actor_update_state")
    let path = child(study, text(artifact, "file"))
    verify_hash(path, text(artifact, "sha256"))
    let data = @artifacts.load_json(path)
    guard text(data, "format") ==
      "moonrobo.moonbit-fixed-model-actor-update-state.v1" else {
      fail(
        "unsupported actor-update state format; raw Torch optimizer state requires explicit conversion",
      )
    }
    let actor_file = child(
      study,
      text(field(result, "checkpoint"), "checkpoint"),
    )
    let actor_sha = digest(actor_file)
    guard actor_sha == text(data, "paired_actor_sha256") &&
      actor_sha == text(field(result, "checkpoint"), "sha256") &&
      text(data, "source_report_sha256") == text(report, "source_report_sha256") &&
      text(field(data, "config"), "actor_feedback_gradient") ==
      "stop-policy-inputs" else {
      fail("actor-update artifact pairing differs")
    }
    let mut expected_model_sha : String? = None
    for reconstruction in array(report, "reconstruction") {
      if text(reconstruction, "method") == text(result, "method") &&
        integer(reconstruction, "seed") == integer(result, "seed") {
        let cycles = array(reconstruction, "cycles")
        guard !cycles.is_empty() else { fail("empty actor reconstruction") }
        expected_model_sha = Some(
          text(cycles[cycles.length() - 1], "model_sha256"),
        )
      }
    }
    let model_sha = digest(text(data, "fixed_model_checkpoint"))
    guard expected_model_sha is Some(expected) &&
      model_sha == expected &&
      model_sha == text(data, "fixed_model_sha256") else {
      fail("actor-update artifact imports another model")
    }
    let (actor, _) = @reference.load_reference_actor(
      actor_file,
      expected_sha256=actor_sha,
    )
    let optimizer : @numeric.Adam = @json.from_json(field(data, "optimizer"))
    guard optimizer.first.length() == actor.parameters().length() &&
      optimizer.second.length() == optimizer.first.length() &&
      optimizer.steps >= 0 else {
      fail("actor-update optimizer shape differs")
    }
    let adapter : String? = @json.from_json(field(data, "sampler_adapter"))
    let sampler = Sampler::new(0, adapter)
    let state = field(data, "sampler_state")
    if text(state, "backend") == "aten-cpu" {
      guard sampler.torch is Some(generator) else {
        fail("ATen sampler state needs its explicit adapter")
      }
      let values : Array[Int32] = @json.from_json(field(state, "state"))
      guard values.all(v => v >= 0 && v <= 255) else {
        fail("invalid sampler byte state")
      }
      generator.restore(Bytes::from_array(values.map(v => v.to_byte())))
    } else {
      guard text(state, "backend") == "moonbit-xorshift32" && adapter is None else {
        fail("sampler backend differs")
      }
      let saved : UInt32 = @json.from_json(field(state, "state"))
      sampler.native.set_state(saved)
    }
    let optimizer_sha = @reference.optimizer_digest(optimizer)
    let sampler_sha = sampler.digest()
    guard optimizer_sha == text(artifact, "optimizer_sha256") &&
      sampler_sha == text(artifact, "sampler_sha256") else {
      fail("independent actor-update reload differs")
    }
    checks.push({
      "method": field(result, "method"),
      "seed": field(result, "seed"),
      "optimizer_sha256": optimizer_sha.to_json(),
      "sampler_sha256": sampler_sha.to_json(),
      "actor_sha256": actor_sha.to_json(),
      "fixed_model_sha256": model_sha.to_json(),
    })
  }
  guard !checks.is_empty() else {
    fail("no stopped-route actor update states found")
  }
  let verification : Json = {
    "format": "moonrobo.g1-actor-update-state-verification.v1",
    "fixed_model_actor_state_only": true,
    "source_report_sha256": digest(study + "/report.json").to_json(),
    "checks": checks.to_json(),
  }
  ignore(
    @artifacts.save_json(
      study + "/actor-update-state-verification.json",
      verification,
    ),
  )
  verification
}
