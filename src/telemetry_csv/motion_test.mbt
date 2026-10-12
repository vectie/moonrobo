///|
test "motion interval rates preserve channel order units and source stencil" {
  let result = @telemetry_csv.motion_csv(
    "timestamp_ms,shoulder,slider,unused\n100,0,10,8\n350,0.5,9,8\n1100,2,6,8",
    ["slider", "shoulder"],
    unit_labels=["m", "rad"],
    order=1,
    max_gap_ms=750L,
  ).unwrap()
  assert_eq(result.recording.channels, ["slider.rate", "shoulder.rate"])
  assert_eq(result.channels[0].output_unit, "(m)/s")
  assert_eq(result.channels[1].source_unit, "rad")
  assert_eq(result.recording.samples.length(), 2)
  assert_eq(result.recording.samples[0].values, [-4.0, 2.0])
  assert_eq(result.recording.samples[1].values, [-4.0, 2.0])
  assert_eq(result.recording.samples[0].timestamp_ms, 350L)
  assert_eq(result.stencils[1].source_sample_indices, [1, 2])
  assert_eq(result.stencils[1].source_timestamps_ms, [350L, 1100L])
  assert_eq(result.stencils[1].source_values, [[9.0, 0.5], [6.0, 2.0]])
  assert_eq(result.unavailable.length(), 1)
  assert_eq(result.unavailable[0].reason, "recording-boundary")
  assert_eq(result.method, "two-point-interval-average")
  assert_eq(result.timestamp_assignment, "right-source-sample")
}

///|
test "motion nonuniform acceleration reproduces quadratic positions" {
  let result = @telemetry_csv.motion_csv(
    "timestamp_ms,q,linear\n10000,0,0\n10250,0.0625,-0.5\n11000,1,-2\n11500,2.25,-3",
    ["q", "linear"],
    unit_labels=["rad", "m"],
    order=2,
    max_gap_ms=750L,
  ).unwrap()
  assert_eq(result.recording.samples.length(), 2)
  assert_eq(result.recording.samples[0].timestamp_ms, 10250L)
  assert_eq(result.recording.samples[1].timestamp_ms, 11000L)
  assert_eq(result.recording.samples[0].values, [2.0, 0.0])
  assert_eq(result.recording.samples[1].values, [2.0, 0.0])
  assert_eq(result.channels[0].output_unit, "(rad)/s^2")
  assert_eq(result.stencils[0].source_sample_indices, [0, 1, 2])
  assert_eq(result.stencils[1].source_timestamps_ms, [10250L, 11000L, 11500L])
  assert_eq(result.unavailable.map(x => x.source_sample_index), [0, 3])
  assert_eq(result.timestamp_assignment, "middle-source-sample")
}

///|
test "motion gaps suppress stencils and resume with independent segments" {
  let text = "timestamp_ms,q\n0,0\n250,0.0625\n1000,1\n1500,2.25\n4000,100\n4250,100.0625\n5000,101\n5500,102.25"
  let rate = @telemetry_csv.motion_csv(
    text,
    ["q"],
    unit_labels=["rad"],
    order=1,
    max_gap_ms=750L,
  ).unwrap()
  assert_eq(rate.recording.samples.length(), 6)
  assert_eq(rate.segment_count, 2)
  assert_eq(rate.gaps.length(), 1)
  assert_eq(rate.gaps[0].duration_ms, 2500L)
  assert_eq(rate.gaps[0].left_sample_index, 3)
  assert_eq(rate.gaps[0].right_timestamp_ms, 4000L)
  assert_eq(rate.unavailable[1].reason, "gap-before")
  assert_eq(rate.stencils[3].source_sample_indices, [4, 5])
  assert_eq(rate.stencils[3].segment, 1)
  let acceleration = @telemetry_csv.motion_csv(
    text,
    ["q"],
    unit_labels=["rad"],
    order=2,
    max_gap_ms=750L,
  ).unwrap()
  assert_eq(acceleration.recording.samples.map(s => s.timestamp_ms), [
    250L, 1000L, 4250L, 5000L,
  ])
  for sample in acceleration.recording.samples {
    assert_eq(sample.values, [2.0])
  }
  assert_eq(acceleration.unavailable.map(s => s.reason), [
    "recording-boundary", "gap-after", "gap-before", "recording-boundary",
  ])
}

///|
test "motion singleton two points and isolated samples are unknown not zero" {
  for order in [1, 2] {
    let one = @telemetry_csv.motion_csv(
      "timestamp_ms,q\n0,4",
      ["q"],
      unit_labels=["rad"],
      order~,
      max_gap_ms=1L,
    ).unwrap()
    assert_eq(one.recording.samples.length(), 0)
    assert_eq(one.unavailable.length(), 1)
    assert_true(one.to_csv() is Err(_))
  }
  let two = @telemetry_csv.motion_csv(
    "timestamp_ms,q\n0,4\n1,4",
    ["q"],
    unit_labels=["rad"],
    order=2,
    max_gap_ms=1L,
  ).unwrap()
  assert_eq(two.recording.samples.length(), 0)
  assert_eq(two.unavailable.length(), 2)
  let isolated = @telemetry_csv.motion_csv(
    "timestamp_ms,q\n0,0\n10,1\n20,2",
    ["q"],
    unit_labels=["rad"],
    order=2,
    max_gap_ms=1L,
  ).unwrap()
  assert_eq(isolated.recording.samples.length(), 0)
  assert_eq(isolated.unavailable[1].reason, "gap-before-and-after")
  assert_eq(isolated.segment_count, 3)
}

///|
test "motion constant positions have supported zero derivatives" {
  for order in [1, 2] {
    let result = @telemetry_csv.motion_csv(
      "timestamp_ms,q\n0,-4\n250,-4\n1000,-4",
      ["q"],
      unit_labels=["rad"],
      order~,
      max_gap_ms=750L,
    ).unwrap()
    for sample in result.recording.samples {
      assert_eq(sample.values, [0.0])
    }
    assert_true(result.to_csv() is Ok(_))
  }
}

///|
test "motion CSV integrates explorer and gap-aware plot" {
  let text = "timestamp_ms,q\n0,0\n250,0.0625\n1000,1\n1500,2.25\n4000,100\n4250,100.0625\n5000,101\n5500,102.25"
  let result = @telemetry_csv.motion_csv(
    text,
    ["q"],
    unit_labels=["rad"],
    order=2,
    max_gap_ms=750L,
  ).unwrap()
  let csv = result.to_csv().unwrap()
  let explored = @telemetry_csv.explore_csv(csv).unwrap()
  assert_eq(explored.sample_count, 4)
  assert_eq(explored.summaries[0].minimum, 2.0)
  assert_eq(explored.summaries[0].maximum, 2.0)
  let plot = @telemetry_csv.plot_csv(
    csv,
    ["q.acceleration"],
    unit_labels=["rad/s^2"],
    max_gap_ms=750L,
  ).unwrap()
  assert_eq(plot.segment_count, 2)
  assert_eq(plot.gap_count, 1)
  assert_true(plot.to_svg().contains("rad/s^2"))
}

///|
test "motion preserves millisecond intervals beyond Double epoch precision" {
  let result = @telemetry_csv.motion_csv(
    "timestamp_ms,q\n9007199254740993,0\n9007199254740994,0.000001\n9007199254740996,0.000009",
    ["q"],
    unit_labels=["rad"],
    order=2,
    max_gap_ms=2L,
  ).unwrap()
  assert_eq(result.recording.samples[0].timestamp_ms, 9007199254740994L)
  assert_true((result.recording.samples[0].values[0] - 2.0).abs() < 0.00000001)
  assert_eq(result.stencils[0].source_timestamps_ms[0], 9007199254740993L)
  assert_true(result.to_csv().unwrap().contains("9007199254740994,"))
}

///|
test "motion huge valid Int64 stencil spans do not overflow duration addition" {
  let result = @telemetry_csv.motion_csv(
    "timestamp_ms,q\n0,0\n4611686018427387904,1\n9223372036854775807,2",
    ["q"],
    unit_labels=["rad"],
    order=2,
    max_gap_ms=9223372036854775807L,
  ).unwrap()
  assert_eq(result.recording.samples.length(), 1)
  assert_true(!result.recording.samples[0].values[0].is_nan())
  assert_true(!result.recording.samples[0].values[0].is_inf())
}

///|
test "motion rejects invalid options and ambiguous selections" {
  let text = "timestamp_ms,q\n0,0\n1,1"
  for order in [0, 3, -1] {
    assert_true(
      @telemetry_csv.motion_csv(
        text,
        ["q"],
        unit_labels=["rad"],
        order~,
        max_gap_ms=1L,
      )
      is Err(_),
    )
  }
  for max_gap_ms in [0L, -1L] {
    assert_true(
      @telemetry_csv.motion_csv(
        text,
        ["q"],
        unit_labels=["rad"],
        order=1,
        max_gap_ms~,
      )
      is Err(_),
    )
  }
  assert_true(
    @telemetry_csv.motion_csv(text, [], unit_labels=[], order=1, max_gap_ms=1L)
    is Err(_),
  )
  assert_true(
    @telemetry_csv.motion_csv(
      text,
      ["q", "q"],
      unit_labels=["rad", "rad"],
      order=1,
      max_gap_ms=1L,
    )
    is Err(_),
  )
  assert_true(
    @telemetry_csv.motion_csv(
      text,
      ["missing"],
      unit_labels=["rad"],
      order=1,
      max_gap_ms=1L,
    )
    is Err(_),
  )
  assert_true(
    @telemetry_csv.motion_csv(
      text,
      ["q"],
      unit_labels=[],
      order=1,
      max_gap_ms=1L,
    )
    is Err(_),
  )
  assert_true(
    @telemetry_csv.motion_csv(
      text,
      ["q"],
      unit_labels=[" "],
      order=1,
      max_gap_ms=1L,
    )
    is Err(_),
  )
}

///|
test "motion validates all input rows and unselected values" {
  for
    text in [
      "timestamp_ms,q,unused\n0,0,0\n1,1,bad", "timestamp_ms,q\n0,0\n0,1", "timestamp_ms,q\n2,0\n1,1",
      "timestamp_ms,q\n-1,0\n1,1", "timestamp_ms,q\n0,0\n10000,NaN", "timestamp_ms,q\n0,0\n10000,1e999",
      "timestamp_ms,q\n0,0\n10000,1,2",
    ] {
    assert_true(
      @telemetry_csv.motion_csv(
        text,
        ["q"],
        unit_labels=["rad"],
        order=1,
        max_gap_ms=1L,
      )
      is Err(_),
    )
  }
}

///|
test "motion arithmetic overflow returns error without nonfinite export" {
  assert_true(
    @telemetry_csv.motion_csv(
      "timestamp_ms,q\n0,-1e308\n1000,1e308",
      ["q"],
      unit_labels=["rad"],
      order=1,
      max_gap_ms=1000L,
    )
    is Err(_),
  )
  assert_true(
    @telemetry_csv.motion_csv(
      "timestamp_ms,q\n0,0\n1,1e308",
      ["q"],
      unit_labels=["rad"],
      order=1,
      max_gap_ms=1L,
    )
    is Err(_),
  )
  assert_true(
    @telemetry_csv.motion_csv(
      "timestamp_ms,q\n0,0\n1000,1e308\n2000,0",
      ["q"],
      unit_labels=["rad"],
      order=2,
      max_gap_ms=1000L,
    )
    is Err(_),
  )
}
