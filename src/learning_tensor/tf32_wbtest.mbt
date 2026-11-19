///|
test "per-op readback separates context and runtime permission" {
  let settings = cuda_fp32_decode(
    FixedArray::from_array([2, 1, 2, -1, -1, 1, 0]),
  )
  assert_eq(settings.matmul_precision, TF32)
  assert_eq(settings.cudnn_conv_precision, IEEE)
  assert_eq(settings.cudnn_rnn_precision, TF32)
  assert_eq(settings.matmul_permission, LibraryMayUse)
  assert_eq(settings.cudnn_conv_permission, ContextDisallows)
  assert_eq(settings.cudnn_rnn_permission, LibraryMayUse)
  assert_false(settings.startup_configuration_locked)
  let disabled = cuda_fp32_decode(FixedArray::from_array([2, 2, 2, 0, 1, 1, 1]))
  assert_eq(disabled.matmul_precision, TF32)
  assert_eq(disabled.matmul_permission, RuntimeOverrideBlocks)
  assert_eq(disabled.cudnn_conv_permission, RuntimeOverrideBlocks)
  assert_true(disabled.startup_configuration_locked)
  let uncertain = cuda_fp32_decode(
    FixedArray::from_array([2, 2, 2, 1, -1, 0, 0]),
  )
  assert_eq(uncertain.matmul_permission, OverrideUnconfirmed)
  assert_eq(uncertain.cudnn_conv_permission, BackendUnavailable)
  assert_eq(fp32_permission(IEEE, -1, true, true), OverrideUnconfirmed)
}

///|
test "FP32 decode rejects invalid native state rather than assuming IEEE" {
  try cuda_fp32_decode(FixedArray::from_array([3, 1, 1, -1, -1, 1, 0])) catch {
    Native(_) => ()
  } noraise {
    _ => fail("unknown precision code must fail")
  }
  try cuda_fp32_decode(FixedArray::from_array([1, 1, 1, 2, -1, 1, 0])) catch {
    Native(_) => ()
  } noraise {
    _ => fail("unknown override must fail")
  }
  try cuda_fp32_decode(FixedArray::from_array([1, 1, 1, -1, -1, 2, 0])) catch {
    Native(_) => ()
  } noraise {
    _ => fail("unknown backend capability must fail")
  }
}
