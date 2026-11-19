///|
/// Source counterpart of the original optional-runtime refusal test. This
/// exercises the real production loader's missing-library boundary, not a GPU.
test "test_optional_backend_reports_missing_runtime_without_breaking_cpu_import" {
  let handle = open_native(
    c_string("/moonrobo/nonexistent-native-apic-library"),
    0,
    2,
  )
  assert_true(@utf8.decode_lossy(error_native(handle)) != "")
  close_native(handle)
  assert_eq(@aligned.joint_names().length(), 29)
}

///|
async test "no-graph runtime inspector rejects invalid device and missing adapter before CUDA" {
  try
    inspect_runtime_library(
      "/missing/apic.so",
      device_id=-1,
      capacity_profile=Paper4096,
    )
  catch {
    Failure(message) =>
      assert_true(message.contains("negative inspection CUDA device"))
    other => raise other
  } noraise {
    _ => fail("invalid inspection device accepted")
  }
  try
    inspect_runtime_library(
      "/moonrobo/nonexistent-native-apic-library",
      capacity_profile=Paper4096,
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("inspection accepted missing adapter")
  }
}
