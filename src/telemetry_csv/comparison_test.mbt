///|
test "run comparison aligns elapsed origins and channels by name" {
  let result = @telemetry_csv.compare_csv(
    "timestamp_ms,joint.rad,temp.c,baseline_only\n1000,1,20,9\n1100,2,22,9", "timestamp_ms,temp.c,joint.rad,candidate_only\n5000,22,2,8\n5100,24,4,8",
  ).unwrap()
  assert_eq(result.channels, ["joint.rad", "temp.c"])
  assert_eq(result.baseline_origin_ms, 1000L)
  assert_eq(result.candidate_origin_ms, 5000L)
  assert_eq(result.compared_count, 2)
  assert_eq(result.interpolated_count, 0)
  assert_eq(result.unmatched_count, 0)
  assert_eq(result.samples[1].elapsed_ms, 100L)
  assert_eq(result.samples[1].baseline, [2.0, 22.0])
  assert_eq(result.samples[1].candidate, [4.0, 24.0])
  assert_eq(result.samples[1].delta, [2.0, 2.0])
  let summary = result.summaries[0]
  assert_eq(summary.mean_delta, 1.5)
  assert_eq(summary.mean_absolute_delta, 1.5)
  assert_true((summary.root_mean_square_delta - 2.5.sqrt()).abs() < 1.0e-12)
  assert_eq(summary.max_absolute_delta, 2.0)
  assert_eq(summary.max_absolute_elapsed_ms, 100L)
}

///|
test "window preserves origins and selected channel ordering" {
  let result = @telemetry_csv.compare_csv(
    "timestamp_ms,x,y\n10,1,10\n20,2,20\n30,3,30",
    "timestamp_ms,y,x\n100,12,3\n110,22,4\n120,32,5",
    channels=["y", "x"],
    start_ms=10L,
    end_ms=10L,
  ).unwrap()
  assert_eq(result.channels, ["y", "x"])
  assert_eq(result.compared_count, 1)
  assert_eq(result.samples[0].elapsed_ms, 10L)
  assert_eq(result.samples[0].baseline_timestamp_ms, 20L)
  assert_eq(result.samples[0].candidate_left_timestamp_ms, 110L)
  assert_eq(result.samples[0].delta, [2.0, 2.0])
}

///|
test "bounded interpolation keeps exact samples and distinguishes uncovered times" {
  let baseline = "timestamp_ms,x\n1000,0\n1100,1\n1200,2\n1300,3\n1400,4\n1500,5\n1600,6"
  let candidate = "timestamp_ms,x\n9000,2\n9200,4\n9500,7"
  let exact = @telemetry_csv.compare_csv(baseline, candidate).unwrap()
  assert_eq(exact.compared_count, 3)
  assert_eq(exact.unmatched_count, 4)
  let result = @telemetry_csv.compare_csv(baseline, candidate, max_gap_ms=200L).unwrap()
  assert_eq(result.compared_count, 4)
  assert_eq(result.interpolated_count, 1)
  assert_eq(result.unmatched_count, 3)
  assert_eq(result.samples[1].candidate, [3.0])
  assert_eq(result.samples[1].delta, [2.0])
  assert_eq(result.samples[1].candidate_left_timestamp_ms, 9000L)
  assert_eq(result.samples[1].candidate_right_timestamp_ms, 9200L)
  assert_eq(result.gaps[0].elapsed_ms, 300L)
  assert_eq(result.gaps[0].reason, "candidate-gap-exceeds-limit")
  assert_eq(result.gaps[2].reason, "outside-candidate-range")
  assert_eq(result.summaries[0].mean_delta, 2.0)
  assert_eq(result.summaries[0].root_mean_square_delta, 2.0)
}

///|
test "signed bias absolute mean and RMS use only paired samples" {
  let result = @telemetry_csv.compare_csv(
    "timestamp_ms,x\n0,0\n10,0\n20,0\n30,1000", "timestamp_ms,x\n0,-3\n10,0\n20,3",
  ).unwrap()
  assert_eq(result.unmatched_count, 1)
  assert_eq(result.summaries[0].mean_delta, 0.0)
  assert_eq(result.summaries[0].mean_absolute_delta, 2.0)
  assert_true(
    (result.summaries[0].root_mean_square_delta - 6.0.sqrt()).abs() < 1.0e-12,
  )
  assert_eq(result.summaries[0].max_absolute_elapsed_ms, 0L)
}

///|
test "empty and wholly unmatched windows have no fabricated statistics" {
  let baseline = "timestamp_ms,x\n10,1\n20,2"
  let candidate = "timestamp_ms,x\n100,1"
  let outside = @telemetry_csv.compare_csv(baseline, candidate, start_ms=10L).unwrap()
  assert_eq(outside.compared_count, 0)
  assert_eq(outside.unmatched_count, 1)
  assert_true(outside.summaries.is_empty())
  let empty = @telemetry_csv.compare_csv(baseline, candidate, start_ms=20L).unwrap()
  assert_eq(empty.compared_count, 0)
  assert_eq(empty.unmatched_count, 0)
  assert_true(empty.summaries.is_empty())
}

///|
test "comparison rejects missing channels and validates excluded data" {
  let input = "timestamp_ms,x\n0,1"
  assert_true(
    @telemetry_csv.compare_csv(input, input, channels=["missing"]) is Err(_),
  )
  assert_true(
    @telemetry_csv.compare_csv(input, input, channels=["x", "x"]) is Err(_),
  )
  assert_true(
    @telemetry_csv.compare_csv(input, "timestamp_ms,y\n0,1") is Err(_),
  )
  assert_true(
    @telemetry_csv.compare_csv(input, input, start_ms=2L, end_ms=1L) is Err(_),
  )
  assert_true(
    @telemetry_csv.compare_csv(input, input, max_gap_ms=-1L) is Err(_),
  )
  assert_true(
    @telemetry_csv.compare_csv(input, input + "\n1,bad", end_ms=0L) is Err(_),
  )
}

///|
test "full precision origins and stable RMS for large finite deltas" {
  let result = @telemetry_csv.compare_csv(
    "timestamp_ms,x\n9223372036854775800,0\n9223372036854775807,0", "timestamp_ms,x\n9007199254740993,1e200\n9007199254741000,-1e200",
  ).unwrap()
  assert_eq(result.samples[1].elapsed_ms, 7L)
  assert_eq(result.samples[1].candidate_left_timestamp_ms, 9007199254741000L)
  assert_eq(result.summaries[0].root_mean_square_delta, 1.0e200)
  assert_eq(result.summaries[0].mean_delta, 0.0)
  assert_true(result.to_json().stringify().contains("\"9223372036854775807\""))
}

///|
test "CSV exports exact interpolation and gap rows in elapsed order" {
  let result = @telemetry_csv.compare_csv(
    "timestamp_ms,x\n10,0\n20,1\n30,2\n40,3",
    "timestamp_ms,x\n100,2\n120,4",
    max_gap_ms=20L,
  ).unwrap()
  let lines = result.to_csv().split("\n").collect()
  assert_eq(lines.length(), 6)
  assert_true(lines[1].has_prefix("0,10,100,100,exact,\"x\",0,2,2"))
  assert_true(lines[2].has_prefix("10,20,100,120,interpolated,\"x\",1,3,2"))
  assert_eq(lines[4], "30,40,,,outside-candidate-range,,,,")
  for line in lines[:5] {
    assert_eq(line.split(",").count(), 9)
  }
}
