///|
fn fp32_fixture(
  enabled : Bool,
  locked~ : Bool = false,
) -> @tensor.CudaFp32Settings {
  let precision = if enabled { @tensor.TF32 } else { @tensor.IEEE }
  let permission = if enabled {
    @tensor.LibraryMayUse
  } else {
    @tensor.ContextDisallows
  }
  {
    matmul_precision: precision,
    cudnn_conv_precision: precision,
    cudnn_rnn_precision: precision,
    nvidia_tf32_override: "unset",
    torch_allow_tf32_cublas_override: "unset",
    cudnn_available: true,
    startup_configuration_locked: locked,
    matmul_permission: permission,
    cudnn_conv_permission: permission,
    cudnn_rnn_permission: permission,
  }
}

///|
test "FP32 config is an explicit Boolean and absence never calls CUDA" {
  assert_eq(fp32_request({}), None)
  assert_eq(fp32_request({ "allow_tf32": true }), Some(true))
  assert_eq(fp32_request({ "allow_tf32": false }), Some(false))
  for value in [Json::null(), Json("true"), Json(1), Json([])] {
    assert_true((try? fp32_request({ "allow_tf32": value })) is Err(_))
    assert_true((try? settings({ "allow_tf32": value }, [])) is Err(_))
  }
  let calls = [0]
  let result = apply_fp32_request(
    None,
    -1,
    () => {
      calls[0] += 1
      false
    },
    _ => {
      calls[0] += 1
      fail("legacy must not configure")
    },
  )
  assert_eq(result, None)
  assert_eq(calls[0], 0)
  let identity : Json = { "config": {}, "legacy": true }
  assert_eq(with_fp32_policy(identity, None), identity)
  assert_eq(source_fp32_policy(identity), None)
  assert_eq(fp32_inference_report({}, None, false), {})
}

///|
test "FP32 capability CPU and locked startup failures precede execution" {
  let calls = [0]
  let configure : (Bool) -> @tensor.CudaFp32Settings raise = enabled => {
    calls[0] += 1
    fp32_fixture(enabled)
  }
  for enabled in [false, true] {
    assert_true(
      (try? apply_fp32_request(Some(enabled), -1, () => true, configure))
      is Err(_),
    )
    assert_true(
      (try? apply_fp32_request(Some(enabled), 0, () => false, configure))
      is Err(_),
    )
  }
  assert_eq(calls[0], 0)
  assert_true(
    (try? apply_fp32_request(Some(true), 0, () => true, enabled => {
      fp32_fixture(enabled, locked=true)
    }))
    is Err(_),
  )
  let applied = apply_fp32_request(Some(true), 0, () => true, configure)
  assert_eq(calls[0], 1)
  assert_eq(applied, Some(fp32_policy_from_settings(true, fp32_fixture(true))))
}

///|
test "FP32 stable identity excludes startup lock but binds request override and DDP" {
  let policy = fp32_policy_from_settings(true, fp32_fixture(true))
  assert_eq(
    policy,
    fp32_policy_from_settings(true, fp32_fixture(true, locked=true)),
  )
  assert_false(
    Json(policy).stringify().contains("startup_configuration_locked"),
  )
  let config : Json = { "allow_tf32": true }
  let original : Json = { "config": config }
  let identity = with_fp32_policy(original, Some(policy))
  assert_eq(original, { "config": config })
  assert_eq(source_fp32_policy(identity), Some(policy))
  assert_true(identity != original)
  let s = settings(config, [])
  assert_true(
    distributed_launch_identity(identity, s) !=
    distributed_launch_identity(original, s),
  )
  let disabled = fp32_policy_from_settings(false, fp32_fixture(false))
  assert_true((try? verify_fp32_source(Some(policy), Some(disabled))) is Err(_))
  let zero_override = fp32_policy_from_settings(false, {
    ..fp32_fixture(false),
    nvidia_tf32_override: "0",
    matmul_permission: @tensor.RuntimeOverrideBlocks,
    cudnn_conv_permission: @tensor.RuntimeOverrideBlocks,
    cudnn_rnn_permission: @tensor.RuntimeOverrideBlocks,
  })
  assert_true(
    (try? verify_fp32_source(Some(disabled), Some(zero_override))) is Err(_),
  )
  verify_fp32_source(Some(policy), Some(policy))
  assert_eq(Json(settings({}, []).learner), Json(s.learner))
  let gib = 1073741824L
  assert_eq(
    Json(estimate_memory(settings({}, []), 100L * gib, Some(100L * gib))),
    Json(estimate_memory(s, 100L * gib, Some(100L * gib))),
  )
}

///|
test "FP32 source refuses historical guesses and inconsistent override readback" {
  let policy = fp32_policy_from_settings(true, fp32_fixture(true))
  let invalid : Array[Json] = [
    { "config": { "allow_tf32": true } },
    { "config": {}, "cuda_fp32_policy": Json(policy) },
    { "config": { "allow_tf32": false }, "cuda_fp32_policy": Json(policy) },
    { "config": { "allow_tf32": true }, "cuda_fp32_policy": Json::null() },
  ]
  for identity in invalid {
    assert_true((try? source_fp32_policy(identity)) is Err(_))
  }
  for
    actual in [
      { ..fp32_fixture(true), matmul_precision: @tensor.IEEE, },
      { ..fp32_fixture(true), cudnn_conv_precision: @tensor.IEEE, },
      {
        ..fp32_fixture(true),
        cudnn_rnn_permission: @tensor.OverrideUnconfirmed,
      },
      { ..fp32_fixture(true), nvidia_tf32_override: "0", },
      { ..fp32_fixture(true), nvidia_tf32_override: "1", },
      { ..fp32_fixture(true), cudnn_available: false, },
    ] {
    assert_true((try? fp32_policy_from_settings(true, actual)) is Err(_))
  }
  assert_true(
    (try? fp32_policy_from_settings(false, {
      ..fp32_fixture(false),
      torch_allow_tf32_cublas_override: "1",
    }))
    is Err(_),
  )
}

///|
test "CPU actor export carries source precision without claiming runtime application" {
  let policy = fp32_policy_from_settings(true, fp32_fixture(true))
  let identity = with_fp32_policy(
    { "config": { "allow_tf32": true } },
    Some(policy),
  )
  let source : InferenceSource = {
    format: "moonrobo.native-actor-source.v1",
    iteration: 1,
    identity,
    motion_names: ["clip"],
    motion_sha256: ["hash"],
    source_fps: 50.0,
    checkpoint_receipt_sha256: "receipt",
    checkpoint_files: {},
    shared_state_digest: Json::null(),
  }
  let restored : InferenceSource = @json.from_json(
    @json.parse(Json(source).stringify()),
  )
  assert_eq(restored.identity, identity)
  assert_eq(source_fp32_policy(restored.identity), Some(policy))
  let exported = fp32_inference_report(
    { "training_executed": false },
    Some(policy),
    false,
  )
  assert_false(setting(exported, "cuda_fp32_policy_applied", true))
  assert_true(
    setting(exported, "cuda_fp32_policy_scope", "").contains(
      "does not configure CUDA",
    ),
  )
  let evaluated = fp32_inference_report({}, Some(policy), true)
  assert_true(setting(evaluated, "cuda_fp32_policy_applied", false))
  assert_eq(
    identity_field(exported, "cuda_fp32_policy"),
    identity_field(evaluated, "cuda_fp32_policy"),
  )
}

///|
test "actual legacy CPU plugin remains usable without optional precision control" {
  guard @env.get_env_var("MOONROBO_TENSOR_LEGACY_LIBRARY") is Some(path) else {
    println(
      "SKIP native CLI FP32 legacy integration: set MOONROBO_TENSOR_LEGACY_LIBRARY",
    )
    return
  }
  let backend = @tensor.Backend::open(path)
  assert_eq(backend.cuda_device_count(), 0)
  assert_false(backend.has_cuda_fp32_control())
  assert_eq(configure_fp32_policy(backend, {}, -1), None)
  try configure_fp32_policy(backend, { "allow_tf32": true }, 0) catch {
    error =>
      assert_true(
        error.to_string().contains("optional CUDA FP32 control extension"),
      )
  } noraise {
    _ => fail("missing optional capability must fail")
  }
  assert_eq(
    backend
    .from_values([1], [2.0], cuda_device=-1, requires_grad=false)
    .square()
    .values(),
    [4.0],
  )
}

///|
async test "paper TF32 opt-in changes only the label and explicit precision request" {
  let original = bounded_json(
    "examples/learning/g1-native-tensor-paper-n2-method-gate.json", 1048576L,
  )
  let optin = bounded_json(
    "examples/learning/g1-native-tensor-paper-n2-tf32-method-gate.json", 1048576L,
  )
  assert_eq(fp32_request(original), None)
  assert_eq(fp32_request(optin), Some(true))
  guard original is Object(original_fields) && optin is Object(optin_fields) else {
    fail("expected config objects")
  }
  let adjusted = optin_fields.copy()
  adjusted.remove("allow_tf32")
  adjusted["profile"] = original_fields["profile"]
  assert_eq(Json::object(adjusted), original)
  let before = settings(original, [])
  let after = settings(optin, [])
  assert_eq(Json(before.learner), Json(after.learner))
  assert_eq(before.environments, 2)
  assert_eq(after.environments, 2)
  let gib = 1073741824L
  assert_eq(
    Json(estimate_memory(before, 48L * gib, Some(100L * gib))),
    Json(estimate_memory(after, 48L * gib, Some(100L * gib))),
  )
}
