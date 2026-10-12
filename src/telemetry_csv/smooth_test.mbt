///|
fn smooth_close(actual : Double, expected : Double) -> Unit raise {
  assert_true((actual - expected).abs() <= 1.0e-12 * expected.abs().max(1.0))
}

///|
test "smooth triangle integrates time and retains raw source window lineage" {
  let r = @telemetry_csv.smooth_csv(
    "timestamp_ms,x,c\n0,0,3\n10,10,3\n20,0,3",
    ["c", "x"],
    half_window_ms=10L,
    max_gap_ms=10L,
  ).unwrap()
  assert_eq(r.recording.channels, ["c.mean", "x.mean"])
  assert_eq(r.source.channels, ["c", "x"])
  assert_eq(r.source.samples[1].values, [3.0, 10.0])
  assert_eq(r.recording.samples.length(), 1)
  assert_eq(r.recording.samples[0].values, [3.0, 5.0])
  assert_eq(r.points[0].source_sample_index, 1)
  assert_eq(r.points[0].first_source_index, 0)
  assert_eq(r.points[0].last_source_index, 2)
  assert_eq(r.points[0].window_start_ms, 0L)
  assert_eq(r.points[0].window_end_ms, 20L)
  assert_eq(r.missing.map(m => m.source_sample_index), [0, 2])
  assert_eq(r.missing.map(m => m.reason), [
    "recording-boundary", "recording-boundary",
  ])
  assert_eq(@telemetry_csv.parse(r.to_csv().unwrap()).unwrap(), r.recording)
}

///|
test "smooth irregular sampling clips boundary intervals rather than averaging rows" {
  let r = @telemetry_csv.smooth_csv(
    "timestamp_ms,x\n0,0\n10,10\n100,0\n110,0",
    ["x"],
    half_window_ms=10L,
    max_gap_ms=90L,
  ).unwrap()
  smooth_close(r.recording.samples[0].values[0], 65.0 / 9.0)
  smooth_close(r.recording.samples[1].values[0], 5.0 / 18.0)
  assert_eq(r.points[0].first_source_index, 0)
  assert_eq(r.points[0].last_source_index, 2)
  assert_eq(r.points[1].first_source_index, 1)
  assert_eq(r.points[1].last_source_index, 3)
}

///|
test "smooth exact window boundaries exclude zero duration neighboring intervals" {
  let r = @telemetry_csv.smooth_csv(
    "timestamp_ms,x\n0,99\n10,0\n20,10\n30,0\n40,99",
    ["x"],
    half_window_ms=10L,
    max_gap_ms=10L,
  ).unwrap()
  assert_eq(r.points[1].first_source_index, 1)
  assert_eq(r.points[1].last_source_index, 3)
  assert_eq(r.recording.samples[1].values, [5.0])
}

///|
test "smooth gaps preserve disconnected exports and no partial windows" {
  let r = @telemetry_csv.smooth_csv(
    "timestamp_ms,x\n0,0\n10,10\n20,0\n100,20\n110,30\n120,20",
    ["x"],
    half_window_ms=10L,
    max_gap_ms=10L,
  ).unwrap()
  assert_eq(r.source_segment_count, 2)
  assert_eq(r.output_segment_count, 2)
  assert_eq(r.points.map(p => p.source_segment), [0, 1])
  smooth_close(r.recording.samples[0].values[0], 5.0)
  smooth_close(r.recording.samples[1].values[0], 25.0)
  assert_eq(r.source_gaps[0].duration_ms, 80L)
  assert_eq(r.source_gaps[0].left_sample_index, 2)
  assert_eq(r.missing.map(m => m.reason), [
    "recording-boundary", "source-gap-overlaps-window", "source-gap-overlaps-window",
    "recording-boundary",
  ])
  assert_true(r.to_csv() is Err(_))
  smooth_close(
    @telemetry_csv.parse(r.to_csv(segment=1).unwrap()).unwrap().samples[0].values[0],
    25.0,
  )
  assert_true(r.to_csv(segment=2) is Err(_))
  assert_true(r.to_csv(segment=-1) is Err(_))
}

///|
test "smooth singleton short segments and all gaps stay unsupported" {
  for
    text in [
      "timestamp_ms,x\n0,7", "timestamp_ms,x\n0,7\n1,7", "timestamp_ms,x\n0,7\n10,7\n20,7",
    ] {
    let r = @telemetry_csv.smooth_csv(
      text,
      ["x"],
      half_window_ms=2L,
      max_gap_ms=1L,
    ).unwrap()
    assert_eq(r.recording.samples.length(), 0)
    assert_eq(r.points.length(), 0)
    assert_eq(r.output_segment_count, 0)
    assert_true(r.to_csv() is Err(_))
    assert_true(r.to_csv(segment=0) is Err(_))
  }
}

///|
test "smooth gap cutoff inclusive and unsupported early segment preserves IDs" {
  let text = "timestamp_ms,x\n0,0\n100,0\n110,10\n120,0"
  let r = @telemetry_csv.smooth_csv(
    text,
    ["x"],
    half_window_ms=10L,
    max_gap_ms=10L,
  ).unwrap()
  assert_eq(r.points[0].source_segment, 1)
  assert_eq(r.output_segment_count, 1)
  assert_eq(
    @telemetry_csv.parse(r.to_csv().unwrap()).unwrap().samples[0].values,
    [5.0],
  )
  let less = @telemetry_csv.smooth_csv(
    text,
    ["x"],
    half_window_ms=10L,
    max_gap_ms=9L,
  ).unwrap()
  assert_eq(less.recording.samples.length(), 0)
}

///|
test "smooth large epoch differences stay exact and Int64 extremes do not wrap" {
  let r = @telemetry_csv.smooth_csv(
    "timestamp_ms,x\n9223372036854775803,0\n9223372036854775805,2\n9223372036854775807,4",
    ["x"],
    half_window_ms=1L,
    max_gap_ms=2L,
  ).unwrap()
  assert_eq(r.recording.samples[0].timestamp_ms, 9223372036854775805L)
  assert_eq(r.recording.samples[0].values, [2.0])
  assert_eq(r.points[0].window_end_ms, 9223372036854775806L)
  let wide = @telemetry_csv.smooth_csv(
    "timestamp_ms,x\n0,1\n4611686018427387903,1\n9223372036854775807,1",
    ["x"],
    half_window_ms=4611686018427387903L,
    max_gap_ms=9223372036854775807L,
  ).unwrap()
  assert_eq(wide.recording.samples[0].values, [1.0])
}

///|
test "smooth finite extreme constants and sign cancellation avoid overflow" {
  let r = @telemetry_csv.smooth_csv(
    "timestamp_ms,x,y,z\n0,1.7e308,-1.7e308,0\n10,1.7e308,0,0\n20,1.7e308,1.7e308,0",
    ["x", "y", "z"],
    half_window_ms=10L,
    max_gap_ms=10L,
  ).unwrap()
  assert_eq(r.recording.samples[0].values, [1.7e308, 0.0, 0.0])
  let small = @telemetry_csv.smooth_csv(
    "timestamp_ms,x\n0,1e-300\n10,1e-300\n20,1e-300",
    ["x"],
    half_window_ms=10L,
    max_gap_ms=10L,
  ).unwrap()
  assert_eq(small.recording.samples[0].values, [1.0e-300])
}

///|
test "smooth rejects invalid options channels and entire malformed recordings" {
  let good = "timestamp_ms,x,y\n0,1,2\n10,2,3\n20,3,4"
  for half in [-1L, 0L, 4611686018427387904L] {
    assert_true(
      @telemetry_csv.smooth_csv(
        good,
        ["x"],
        half_window_ms=half,
        max_gap_ms=10L,
      )
      is Err(_),
    )
  }
  for gap in [-1L, 0L] {
    assert_true(
      @telemetry_csv.smooth_csv(good, ["x"], half_window_ms=1L, max_gap_ms=gap)
      is Err(_),
    )
  }
  for channels in [[], ["absent"], ["x", "x"], [""]] {
    assert_true(
      @telemetry_csv.smooth_csv(
        good,
        channels,
        half_window_ms=1L,
        max_gap_ms=10L,
      )
      is Err(_),
    )
  }
  for
    bad in [
      "timestamp_ms,x", "timestamp_ms,x,y\n0,1,NaN", "timestamp_ms,x\n0,1\n0,2",
      "timestamp_ms,x\n-1,1", "timestamp_ms,x\n0,1\n10,Infinity", "timestamp_ms,x\n0,1\n10,2\n20,bad",
    ] {
    assert_true(
      @telemetry_csv.smooth_csv(bad, ["x"], half_window_ms=1L, max_gap_ms=10L)
      is Err(_),
    )
  }
}

///|
test "smooth bounded work refuses excessive overlapping interval contributions" {
  let text = StringBuilder()
  text.write_string("timestamp_ms,x\n")
  for i in 0..<2100 {
    text.write_string("\{i},1\n")
  }
  assert_true(
    @telemetry_csv.smooth_csv(
      text.to_string(),
      ["x"],
      half_window_ms=500L,
      max_gap_ms=1L,
    )
    is Err(_),
  )
}

///|
test "smooth derived export composes with motion without manufacturing boundary rows" {
  let r = @telemetry_csv.smooth_csv(
    "timestamp_ms,x\n0,0\n100,1\n200,2\n300,3\n400,4",
    ["x"],
    half_window_ms=100L,
    max_gap_ms=100L,
  ).unwrap()
  let motion = @telemetry_csv.motion_csv(
    r.to_csv().unwrap(),
    ["x.mean"],
    unit_labels=["rad"],
    order=1,
    max_gap_ms=100L,
  ).unwrap()
  assert_eq(motion.recording.samples.length(), 2)
  for sample in motion.recording.samples {
    smooth_close(sample.values[0], 10.0)
  }
}

///|
test "smooth row limit validates and refuses oversized recordings" {
  let text = StringBuilder()
  text.write_string("timestamp_ms,x\n")
  for i in 0..<100001 {
    text.write_string("\{i},1\n")
  }
  assert_true(
    @telemetry_csv.smooth_csv(
      text.to_string(),
      ["x"],
      half_window_ms=1L,
      max_gap_ms=1L,
    )
    is Err(_),
  )
}
