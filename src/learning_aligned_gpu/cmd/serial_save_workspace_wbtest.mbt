///|
test "serial archive admission is strict opt-in and omitted from inference settings" {
  let config : Json = {
    "capacity_profile": "paper-4096",
    "memory_admission_percent": 80,
    "num_envs": 256,
    "buffer_steps": 1000,
    "wm_batch": 2048,
    "pi_batch": 512,
    "wm_hidden": [2048, 2048, 2048],
    "pi_hidden": [2048, 1024, 512, 256],
    "critic_hidden": [256, 128],
    "observation_mode": "smc",
  }
  let args = [
    "aligned-gpu", "preflight", "--checkpoint-format", "stream-v2", "--cuda-memory-telemetry",
  ]
  assert_true(!settings(config, args).serial_optimizer_save_workspace)
  guard config is Object(fields) else { fail("object config expected") }
  let enabled = fields.copy()
  enabled["serial_optimizer_save_workspace"] = true
  let serial = settings(Json(enabled), args)
  assert_true(serial.serial_optimizer_save_workspace)
  let physical : PhysicsPreflight = {
    manifest_sha256: "5125dd55906ec0e5ffc9669007f60266137ee866c3b528574f6a11e6fa325c9b",
    bundle_bytes: 230465552L,
    shared_region_bytes: 47905609L,
    largest_file_bytes: 1L,
    manifest_bytes: 106611L,
    manifest_identity: Json::null(),
  }
  let plan = estimate_memory(
    serial,
    107176316928L,
    Some(81920348160L),
    physical~,
    include_restore=false,
    motion_manifest_bytes=38601L,
  )
  assert_eq(plan.peak_bytes, 58799493008L)
  assert_eq(plan.budget_bytes, 64740478976L)
  assert_eq(
    plan.phase_plan.unwrap().counts["serial_optimizer_save_workspace"],
    1L,
  )
  let projected = evaluation_runtime_config(Json(enabled))
  assert_true(
    !settings(projected, ["aligned-gpu", "evaluate"]).serial_optimizer_save_workspace,
  )
  assert_eq(enabled["serial_optimizer_save_workspace"], true)
  for value in [Json::null(), Json("true"), Json(1)] {
    let invalid = fields.copy()
    invalid["serial_optimizer_save_workspace"] = value
    try settings(Json(invalid), args) catch {
      _ => ()
    } noraise {
      _ => fail("non-boolean serial save policy accepted")
    }
  }
  let invalid_policies : Array[Json] = [
    { "serial_optimizer_save_workspace": true },
    {
      "capacity_profile": "paper-4096",
      "serial_optimizer_save_workspace": true,
    },
  ]
  for bad in invalid_policies {
    try serial_optimizer_save_workspace_request(bad) catch {
      _ => ()
    } noraise {
      _ => fail("serial save policy lacks explicit paper memory reserve")
    }
  }
  try settings(Json(enabled), ["--checkpoint-format", "stream-v2"]) catch {
    _ => ()
  } noraise {
    _ => fail("serial save policy accepted without CUDA memory telemetry")
  }
}
