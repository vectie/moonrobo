///|
test "passive definition hashing retains decorator and closes multiline signature" {
  let source =
    #|# license
    #|@wp.kernel(enable_backward=False)
    #|def example(
    #|    source: wp.array(dtype=wp.float32),
    #|):
    #|    i = wp.tid()
    #|    source[i] = 0.0
    #|
    #|
    #|@wp.kernel
    #|def different():
    #|    pass
  assert_eq(
    definition(source, "example"),
    "@wp.kernel(enable_backward=False)\ndef example(\n    source: wp.array(dtype=wp.float32),\n):\n    i = wp.tid()\n    source[i] = 0.0\n",
  )
}

///|
test "compile options require explicit matching architecture" {
  assert_true(
    effective_options(["--gpu-architecture=compute_90"], "ptx").contains(
      "--std=c++17",
    ),
  )
  for
    (options, kind) in [
      ([], "ptx"),
      (["--gpu-architecture=sm_90"], "ptx"),
      (["--gpu-architecture=compute_90"], "cubin"),
      (["--gpu-architecture=compute_90", "-arch=compute_90"], "ptx"),
    ] {
    try effective_options(options, kind) catch {
      _ => ()
    } noraise {
      _ => fail("invalid architecture accepted")
    }
  }
}
