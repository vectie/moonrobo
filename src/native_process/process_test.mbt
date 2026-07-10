///|
test "native process reports invalid inputs" {
  let started = @native_process.start_shell_script("")
  assert_true(started is Err(_))
  let run = @native_process.run_shell_script("")
  assert_true(run is Err(_))
  let stopped = @native_process.stop(0)
  assert_true(stopped is Err(_))
  assert_false(@native_process.is_running(0))
}

///|
test "native process waits for shell script exit status" {
  let path = "/tmp/moonrobo-native-process-run-test.sh"
  @fsx.write_string_to_file(path, "exit 7\n") catch {
    _ => fail("failed to write synchronous process test script")
  }
  assert_eq(@native_process.run_shell_script(path).unwrap(), 7)
}

///|
test "native process starts and stops shell script" {
  let path = "/tmp/moonrobo-native-process-test.sh"
  @fsx.write_string_to_file(
    path, "trap 'exit 0' TERM\nwhile true; do sleep 1; done\n",
  ) catch {
    _ => fail("failed to write process test script")
  }
  let started = @native_process.start_shell_script(path).unwrap()
  assert_true(started.pid > 0)
  assert_true(@native_process.is_running(started.pid))
  let stopped = @native_process.stop(started.pid).unwrap()
  assert_true(stopped)
}
