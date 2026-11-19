///|
async test "compiled training admits the production recipe, not chunked or TF32 substitutes" {
  let config = bounded_json(
    "examples/learning/g1-bones-paper-partial-compiled-bf16.json", 1048576L,
  )
  let args = [
    "exe", "train", "--cuda-memory-telemetry", "--checkpoint-format", "stream-v2",
    "--compiled-bundle", "/bundle",
  ]
  assert_eq(bf16_profile(config, settings(config, args), args), Some("/bundle"))
  let evaluation = settings(evaluation_runtime_config(config), [
    "exe", "evaluate",
  ])
  assert_eq(Json(evaluation.learner), Json(settings(config, args).learner))
  guard config is Object(fields) else { fail("expected config") }
  for
    (name, value) in [
      ("pi_microbatch", Json(512)),
      ("allow_tf32", Json(true)),
      ("observation_mode", Json("paper")),
      ("wm_batch", Json(1024)),
    ] {
    let copy = fields.copy()
    copy[name] = value
    let bad = Json::object(copy)
    try bf16_profile(bad, settings(bad, args), args) catch {
      _ => ()
    } noraise {
      _ => fail("accepted changed signature: " + name)
    }
  }
  assert_eq(bf16_profile({}, settings({}, []), []), None)
}

///|
test "atlas host goal uses the same projected left axis as corrected imagination" {
  // R = Ry(90 deg) Rx(45 deg). The forward column is vertical.
  let c = 0.5.sqrt()
  let r = [0.0, c, c, 0.0, c, -c, -1.0, 0.0, 0.0]
  let h = @aligned.yaw_mat(r, atlas=true)
  assert_true((h[0] - c).abs() < 1.0e-12 && (h[3] + c).abs() < 1.0e-12)
  // A nonvertical case where the two charts give different headings.
  let t = 0.75.sqrt()
  let r2 = [0.5, t * c, t * c, 0.0, c, -c, -t, 0.5 * c, 0.5 * c]
  assert_true(@aligned.yaw_mat(r2, atlas=true)[3] < -0.6)
  assert_eq(@aligned.yaw_mat(r2)[3], 0.0)
}
