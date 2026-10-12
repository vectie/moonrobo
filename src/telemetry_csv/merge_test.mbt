///|
test "merge combines disjoint channels in source order and round trips numeric CSV" {
  let result = @telemetry_csv.merge_csv(
    "timestamp_ms,y,x\n1000,2,1\n1100,4,3", "timestamp_ms,current,temp\n1000,8,20\n1100,9,21",
  ).unwrap()
  assert_eq(result.format, "moonrobo.telemetry-merge.v1")
  assert_eq(result.recording.channels, [
    "primary.y", "primary.x", "secondary.current", "secondary.temp",
  ])
  assert_eq(result.recording.samples[1].values, [4.0, 3.0, 9.0, 21.0])
  assert_eq(result.merged_count, 2)
  assert_eq(result.exact_count, 2)
  assert_eq(result.nearest_count, 0)
  assert_eq(result.secondary_unused_count, 0)
  assert_eq(
    @telemetry_csv.parse(result.to_csv().unwrap()).unwrap(),
    result.recording,
  )
}

///|
test "merge never silently rebases different clocks and supports signed explicit offsets" {
  let first = "timestamp_ms,x\n1000,1\n1100,2"
  let second = "timestamp_ms,z\n5000,7\n5100,8"
  let unchanged = @telemetry_csv.merge_csv(first, second).unwrap()
  assert_eq(unchanged.merged_count, 0)
  assert_eq(unchanged.unmatched.length(), 2)
  assert_true(unchanged.to_csv() is Err(_))
  let shifted = @telemetry_csv.merge_csv(
    first,
    second,
    secondary_offset_ms=-4000L,
  ).unwrap()
  assert_eq(shifted.merged_count, 2)
  assert_eq(shifted.matches[1].timestamp_ms, 1100L)
  assert_eq(shifted.matches[1].secondary_timestamp_ms, 5100L)
  assert_eq(shifted.matches[1].secondary_aligned_timestamp_ms, 1100L)
  assert_eq(shifted.matches[1].delta_ms, 0L)
  let forward = @telemetry_csv.merge_csv(
    second,
    first,
    secondary_offset_ms=4000L,
  ).unwrap()
  assert_eq(forward.recording.samples[0].timestamp_ms, 5000L)
  assert_eq(forward.exact_count, 2)
}

///|
test "nearest merge includes tolerance boundary chooses earlier ties and reports reuse" {
  let result = @telemetry_csv.merge_csv(
    "timestamp_ms,x\n0,1\n5,2\n10,3",
    "timestamp_ms,z\n0,7\n10,8\n30,9",
    tolerance_ms=5L,
  ).unwrap()
  assert_eq(result.exact_count, 2)
  assert_eq(result.nearest_count, 1)
  assert_eq(result.reused_count, 1)
  assert_eq(result.secondary_unused_count, 1)
  assert_eq(result.matches[1].secondary_timestamp_ms, 0L)
  assert_eq(result.matches[1].delta_ms, -5L)
  assert_true(result.matches[1].secondary_reused)
  assert_eq(result.recording.samples[1].values, [2.0, 7.0])
  assert_true(!result.matches[2].secondary_reused)
}

///|
test "nearest merge picks later samples when closer and drops out of tolerance rows" {
  let result = @telemetry_csv.merge_csv(
    "timestamp_ms,x\n0,1\n7,2\n10,3\n15,4\n30,5",
    "timestamp_ms,z\n2,7\n10,8",
    tolerance_ms=3L,
  ).unwrap()
  assert_eq(result.merged_count, 3)
  assert_eq(result.matches[0].delta_ms, 2L)
  assert_eq(result.matches[1].secondary_timestamp_ms, 10L)
  assert_eq(result.matches[1].delta_ms, 3L)
  assert_eq(result.unmatched.length(), 2)
  assert_eq(result.unmatched[0].timestamp_ms, 15L)
  assert_eq(result.unmatched[0].delta_ms, -5L)
  assert_eq(result.unmatched[1].nearest_secondary_timestamp_ms, 10L)
  assert_eq(result.unmatched[1].reason, "nearest-sample-exceeds-tolerance")
  assert_eq(
    @telemetry_csv.parse(result.to_csv().unwrap()).unwrap().samples.length(),
    3,
  )
}

///|
test "prefixes preserve same-name sensors and allow explicit original names" {
  let input = "timestamp_ms,x\n0,1"
  let result = @telemetry_csv.merge_csv(
    input,
    input,
    primary_prefix="pose",
    secondary_prefix="arm",
  ).unwrap()
  assert_eq(result.recording.channels, ["pose.x", "arm.x"])
  assert_true(
    @telemetry_csv.merge_csv(
      input,
      input,
      primary_prefix="",
      secondary_prefix="",
    )
    is Err(_),
  )
  assert_true(
    @telemetry_csv.merge_csv(
      input,
      input,
      primary_prefix="a",
      secondary_prefix="a",
    )
    is Err(_),
  )
  assert_true(
    @telemetry_csv.merge_csv(
      "timestamp_ms,aux.x\n0,1",
      input,
      primary_prefix="",
      secondary_prefix="aux",
    )
    is Err(_),
  )
  let original = @telemetry_csv.merge_csv(
    input,
    "timestamp_ms,y\n0,2",
    primary_prefix="",
    secondary_prefix="",
  ).unwrap()
  assert_eq(original.recording.channels, ["x", "y"])
  assert_eq(
    @telemetry_csv.parse(original.to_csv().unwrap()).unwrap(),
    original.recording,
  )
}

///|
test "merge rejects malformed inputs unused invalid samples and invalid options" {
  let input = "timestamp_ms,x\n0,1"
  assert_true(
    @telemetry_csv.merge_csv(input, input, tolerance_ms=-1L) is Err(_),
  )
  for
    prefix in [
      "bad,label", "quote\"", "line\nbreak", "line\rbreak", " leading", "trailing ",
    ] {
    assert_true(
      @telemetry_csv.merge_csv(input, input, primary_prefix=prefix) is Err(_),
    )
    assert_true(
      @telemetry_csv.merge_csv(input, input, secondary_prefix=prefix) is Err(_),
    )
  }
  assert_true(@telemetry_csv.merge_csv(input + "\n1,bad", input) is Err(_))
  assert_true(@telemetry_csv.merge_csv(input, input + "\n100,bad") is Err(_))
  assert_true(@telemetry_csv.merge_csv("timestamp_ms,x", input) is Err(_))
  assert_true(@telemetry_csv.merge_csv(input, input + "\n0,2") is Err(_))
}

///|
test "merge protects full Int64 precision and both offset range limits" {
  let high = "timestamp_ms,x\n9223372036854775806,1\n9223372036854775807,2"
  let shifted = @telemetry_csv.merge_csv(
    high,
    "timestamp_ms,z\n9223372036854775805,3",
    secondary_offset_ms=1L,
    tolerance_ms=1L,
  ).unwrap()
  assert_eq(
    shifted.matches[0].secondary_aligned_timestamp_ms,
    9223372036854775806L,
  )
  assert_eq(shifted.matches[1].delta_ms, -1L)
  assert_true(shifted.to_json().stringify().contains("\"9223372036854775807\""))
  assert_eq(
    @telemetry_csv.parse(shifted.to_csv().unwrap()).unwrap(),
    shifted.recording,
  )
  assert_true(
    @telemetry_csv.merge_csv(high, high, secondary_offset_ms=1L) is Err(_),
  )
  assert_true(
    @telemetry_csv.merge_csv(
      high,
      "timestamp_ms,x\n0,1",
      secondary_offset_ms=-1L,
    )
    is Err(_),
  )
  assert_true(
    @telemetry_csv.merge_csv(
      high,
      high,
      secondary_offset_ms=-9223372036854775808L,
    )
    is Err(_),
  )
  let endpoints = @telemetry_csv.merge_csv(
    "timestamp_ms,x\n0,1",
    "timestamp_ms,z\n9223372036854775807,2",
    tolerance_ms=9223372036854775807L,
  ).unwrap()
  assert_eq(endpoints.matches[0].delta_ms, 9223372036854775807L)
  let reversed = @telemetry_csv.merge_csv(
    "timestamp_ms,x\n9223372036854775807,1",
    "timestamp_ms,z\n0,2",
    tolerance_ms=9223372036854775807L,
  ).unwrap()
  assert_eq(reversed.matches[0].delta_ms, -9223372036854775807L)
}

///|
test "singleton nearest sample and source values are preserved without interpolation" {
  let result = @telemetry_csv.merge_csv(
    "timestamp_ms,x\n9,1\n10,2\n11,3",
    "timestamp_ms,z\n10,-1e200",
    tolerance_ms=1L,
  ).unwrap()
  assert_eq(result.merged_count, 3)
  assert_eq(result.reused_count, 2)
  assert_eq(result.recording.samples[0].values[1], -1.0e200)
  assert_eq(result.recording.samples[2].values[1], -1.0e200)
  assert_eq(
    @telemetry_csv.parse(result.to_csv().unwrap()).unwrap(),
    result.recording,
  )
}

///|
test "merged CSV feeds existing trajectory explorer and run comparison" {
  let result = @telemetry_csv.merge_csv(
    "timestamp_ms,x\n1000,0\n1500,3\n2000,6",
    "timestamp_ms,y,temp\n1002,0,20\n1498,4,21\n2000,8,22",
    primary_prefix="",
    secondary_prefix="",
    tolerance_ms=2L,
  ).unwrap()
  let csv = result.to_csv().unwrap()
  let path = @telemetry_csv.trajectory_csv(csv, "x", "y", units="m").unwrap()
  assert_eq(path.observed_distance, 10.0)
  assert_eq(path.peak_interval_speed, 10.0)
  let explored = @telemetry_csv.explore_csv(csv, start_ms=1500L).unwrap()
  assert_eq(explored.sample_count, 2)
  assert_eq(explored.summaries[2].first, 21.0)
  let comparison = @telemetry_csv.compare_csv(csv, csv).unwrap()
  assert_eq(comparison.compared_count, 3)
  assert_eq(comparison.summaries[0].max_absolute_delta, 0.0)
}
