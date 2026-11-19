///|
test "v1 and v2 native archive runtime descriptions remain frozen" {
  let robot = profile()
  for legacy in [true, false] {
    assert_true(
      robot.sensor_contract(legacy~)
      is {
        "runtime": "native LibTorch/MoonBit archive; E1 runner masks unused outputs; no ONNX export",
        ..
      },
    )
  }
}
