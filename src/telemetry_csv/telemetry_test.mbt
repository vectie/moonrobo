///|
test "joint and sensor CSV preserves timestamps and computes channel extrema" {
  let text = "timestamp_ms,joint.shoulder.rad,sensor.temperature.c\n1000,0.5,20\n1020,-0.25,21\n1100,1.5,19\n"
  let result = @telemetry_csv.explore_csv(text).unwrap()
  assert_eq(result.sample_count, 3)
  assert_eq(result.channels, ["joint.shoulder.rad", "sensor.temperature.c"])
  assert_eq(result.samples[1].timestamp_ms, 1020L)
  assert_eq(result.summaries[0].minimum, -0.25)
  assert_eq(result.summaries[0].maximum, 1.5)
  assert_eq(result.summaries[1].first, 20.0)
  assert_eq(result.summaries[1].last, 19.0)
}

///|
test "inclusive window retains real times and recomputes statistics" {
  let result = @telemetry_csv.explore_csv(
    "timestamp_ms,x\n10,8\n20,2\n30,4\n40,9",
    start_ms=20L,
    end_ms=30L,
  ).unwrap()
  assert_eq(result.sample_count, 2)
  assert_eq(result.samples[0].timestamp_ms, 20L)
  assert_eq(result.samples[1].timestamp_ms, 30L)
  assert_eq(result.summaries[0].minimum, 2.0)
  assert_eq(result.summaries[0].maximum, 4.0)
}

///|
test "empty window is a valid empty replay" {
  let result = @telemetry_csv.explore_csv("timestamp_ms,x\n1,2", start_ms=2L).unwrap()
  assert_eq(result.sample_count, 0)
  assert_eq(result.channels, ["x"])
  assert_true(result.summaries.is_empty())
  assert_true(result.samples.is_empty())
}

///|
test "CRLF whitespace blank lines and scientific notation" {
  let result = @telemetry_csv.parse(
    "\r\n timestamp_ms , x \r\n 0 , -1.25e2 \r\n\r\n1,3e-1\r\n",
  ).unwrap()
  assert_eq(result.samples[0].values, [-125.0])
  assert_eq(result.samples[1].values, [0.3])
}

///|
test "timestamps retain full int64 precision" {
  let result = @telemetry_csv.parse(
    "timestamp_ms,x\n9007199254740993,1\n9223372036854775807,2",
  ).unwrap()
  assert_eq(result.samples[0].timestamp_ms, 9007199254740993L)
  assert_eq(result.samples[1].timestamp_ms, 9223372036854775807L)
}

///|
test "reject invalid headers and empty inputs" {
  for
    text in [
      "", "timestamp_ms,x", "time,x\n1,2", "timestamp_ms\n1", "timestamp_ms,x,x\n1,2,3",
      "timestamp_ms,\n1,2", "timestamp_ms,timestamp_ms\n1,2",
    ] {
    assert_true(@telemetry_csv.parse(text) is Err(_), msg=text)
  }
}

///|
test "reject malformed numeric rows with source line" {
  for
    text in [
      "timestamp_ms,x\n1,", "timestamp_ms,x\n1,2,3", "timestamp_ms,x\n1", "timestamp_ms,x\n1,abc",
      "timestamp_ms,x\n1,NaN", "timestamp_ms,x\n1,Infinity", "timestamp_ms,x\n1,1e9999",
    ] {
    let error = match @telemetry_csv.parse(text) {
      Err(e) => e
      Ok(_) => fail(text)
    }
    assert_true(error.contains("line 2:"))
  }
}

///|
test "reject bad duplicate descending and overflow timestamps" {
  for
    text in [
      "timestamp_ms,x\n-1,2", "timestamp_ms,x\n1.5,2", "timestamp_ms,x\n9223372036854775808,2",
      "timestamp_ms,x\n1,2\n1,3", "timestamp_ms,x\n2,2\n1,3",
    ] {
    assert_true(@telemetry_csv.parse(text) is Err(_), msg=text)
  }
}

///|
test "quoted dialect fails explicitly" {
  assert_true(@telemetry_csv.parse("timestamp_ms,\"x\"\n1,2") is Err(_))
}

///|
test "bad windows rejected and malformed excluded rows still validated" {
  assert_true(
    @telemetry_csv.explore_csv("timestamp_ms,x\n1,2", start_ms=-1L) is Err(_),
  )
  assert_true(
    @telemetry_csv.explore_csv("timestamp_ms,x\n1,2", start_ms=2L, end_ms=1L)
    is Err(_),
  )
  assert_true(
    @telemetry_csv.explore_csv("timestamp_ms,x\n1,2\n2,bad", end_ms=1L)
    is Err(_),
  )
}
