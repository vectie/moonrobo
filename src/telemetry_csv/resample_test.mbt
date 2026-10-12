///|
fn resample_close(actual : Double, expected : Double) -> Unit raise {
  assert_true((actual - expected).abs() <= 1.0e-12 * expected.abs().max(1.0))
}

///|
test "resample irregular observations preserves ordered channels and exact brackets" {
  let r = @telemetry_csv.resample_csv(
    "timestamp_ms,x,y\n100,0,10\n350,5,20\n600,10,30",
    ["y", "x"],
    start_ms=100L,
    end_ms=600L,
    step_ms=100L,
    max_gap_ms=250L,
  ).unwrap()
  assert_eq(r.grid_count, 6)
  assert_eq(r.exact_count, 2)
  assert_eq(r.interpolated_count, 4)
  assert_eq(r.recording.channels, ["y", "x"])
  assert_eq(r.recording.samples.map(s => s.timestamp_ms), [
    100L, 200L, 300L, 400L, 500L, 600L,
  ])
  for i, sample in r.recording.samples {
    resample_close(sample.values[0], 10.0 + i.to_double() * 4.0)
    resample_close(sample.values[1], i.to_double() * 2.0)
  }
  assert_eq(r.points[0].left_sample_index, 0)
  assert_eq(r.points[0].right_sample_index, 0)
  assert_eq(r.points[0].right_weight, 0.0)
  assert_eq(r.points[1].left_timestamp_ms, 100L)
  assert_eq(r.points[1].right_timestamp_ms, 350L)
  assert_eq(r.points[1].left_values, [10.0, 0.0])
  assert_eq(r.points[1].right_values, [20.0, 5.0])
  assert_eq(r.points[1].right_weight, 0.4)
  assert_eq(r.points[5].right_sample_index, 2)
}

///|
test "resample requested start anchors grid and unaligned end is not appended" {
  let r = @telemetry_csv.resample_csv(
    "timestamp_ms,x\n0,0\n1000,10",
    ["x"],
    start_ms=125L,
    end_ms=550L,
    step_ms=125L,
    max_gap_ms=1000L,
  ).unwrap()
  assert_eq(r.recording.samples.map(s => s.timestamp_ms), [
    125L, 250L, 375L, 500L,
  ])
  assert_eq(r.exact_count, 0)
  assert_eq(r.recording.samples[0].values, [1.25])
}

///|
test "resample records gaps outside range and supports disconnected segment export" {
  let r = @telemetry_csv.resample_csv(
    "timestamp_ms,x\n100,0\n350,5\n600,10\n1900,40\n2100,50",
    ["x"],
    start_ms=0L,
    end_ms=2300L,
    step_ms=100L,
    max_gap_ms=300L,
  ).unwrap()
  assert_eq(r.grid_count, 24)
  assert_eq(r.exact_count, 4)
  assert_eq(r.interpolated_count, 5)
  assert_eq(r.missing.length(), 15)
  assert_eq(
    r.missing.filter(p => p.reason == "outside-source-range").length(),
    3,
  )
  assert_eq(r.missing[1].timestamp_ms, 700L)
  assert_eq(r.missing[1].reason, "source-gap-exceeds-limit")
  assert_eq(r.source_segment_count, 2)
  assert_eq(r.output_segment_count, 2)
  assert_eq(r.source_gaps[0].duration_ms, 1300L)
  assert_eq(r.source_gaps[0].left_sample_index, 2)
  assert_eq(r.source_gaps[0].right_sample_index, 3)
  assert_eq(r.points[6].source_segment, 1)
  assert_true(r.to_csv() is Err(_))
  let first = @telemetry_csv.parse(r.to_csv(segment=0).unwrap()).unwrap()
  assert_eq(first.samples.length(), 6)
  let second = @telemetry_csv.parse(r.to_csv(segment=1).unwrap()).unwrap()
  assert_eq(second.samples.length(), 3)
  assert_eq(second.samples[1].values, [45.0])
  assert_true(r.to_csv(segment=2) is Err(_))
  assert_true(r.to_csv(segment=-1) is Err(_))
}

///|
test "resample coarse grid cannot conceal a skipped source gap in CSV" {
  let r = @telemetry_csv.resample_csv(
    "timestamp_ms,x\n0,0\n10,1\n90,9\n100,10",
    ["x"],
    start_ms=0L,
    end_ms=100L,
    step_ms=100L,
    max_gap_ms=20L,
  ).unwrap()
  assert_eq(r.missing.length(), 0)
  assert_eq(r.source_gaps.length(), 1)
  assert_eq(r.output_segment_count, 2)
  assert_true(r.to_csv() is Err(_))
  assert_eq(r.points.map(p => p.source_segment), [0, 1])
}

///|
test "resample singleton empty support and explicit exact-only mode" {
  let r = @telemetry_csv.resample_csv(
    "timestamp_ms,x\n50,7",
    ["x"],
    start_ms=0L,
    end_ms=100L,
    step_ms=25L,
    max_gap_ms=0L,
  ).unwrap()
  assert_eq(r.grid_count, 5)
  assert_eq(r.exact_count, 1)
  assert_eq(r.missing.length(), 4)
  assert_eq(
    @telemetry_csv.parse(r.to_csv().unwrap()).unwrap().samples[0].values,
    [7.0],
  )
  let empty = @telemetry_csv.resample_csv(
    "timestamp_ms,x\n50,7",
    ["x"],
    start_ms=0L,
    end_ms=40L,
    step_ms=10L,
    max_gap_ms=100L,
  ).unwrap()
  assert_eq(empty.output_segment_count, 0)
  assert_true(empty.to_csv() is Err(_))
  let exact = @telemetry_csv.resample_csv(
    "timestamp_ms,x\n0,0\n100,1",
    ["x"],
    start_ms=0L,
    end_ms=100L,
    step_ms=50L,
    max_gap_ms=0L,
  ).unwrap()
  assert_eq(exact.exact_count, 2)
  assert_eq(exact.interpolated_count, 0)
  assert_eq(exact.missing[0].timestamp_ms, 50L)
}

///|
test "resample gap cutoff is inclusive and exact observations remain regardless" {
  for limit in [99L, 100L] {
    let r = @telemetry_csv.resample_csv(
      "timestamp_ms,x\n0,0\n100,10",
      ["x"],
      start_ms=0L,
      end_ms=100L,
      step_ms=50L,
      max_gap_ms=limit,
    ).unwrap()
    assert_eq(r.exact_count, 2)
    assert_eq(r.interpolated_count, if limit == 100L { 1 } else { 0 })
  }
}

///|
test "resample integer time precision survives large origin and Int64 endpoint" {
  let r = @telemetry_csv.resample_csv(
    "timestamp_ms,x\n9223372036854775803,0\n9223372036854775807,8",
    ["x"],
    start_ms=9223372036854775803L,
    end_ms=9223372036854775807L,
    step_ms=1L,
    max_gap_ms=4L,
  ).unwrap()
  assert_eq(r.recording.samples.map(s => s.values[0]), [0.0, 2.0, 4.0, 6.0, 8.0])
  assert_eq(r.points[1].right_weight, 0.25)
  let span = @telemetry_csv.resample_csv(
    "timestamp_ms,x\n0,0\n9223372036854775807,2",
    ["x"],
    start_ms=0L,
    end_ms=9223372036854775807L,
    step_ms=9223372036854775807L,
    max_gap_ms=9223372036854775807L,
  ).unwrap()
  assert_eq(span.grid_count, 2)
  assert_eq(span.exact_count, 2)
}

///|
test "resample finite extreme endpoints avoid intermediate overflow" {
  for
    text in [
      "timestamp_ms,x\n0,1.7e308\n4,-1.7e308", "timestamp_ms,x\n0,1.7e308\n4,1.6e308",
      "timestamp_ms,x\n0,-1.7e308\n4,-1.6e308",
    ] {
    let r = @telemetry_csv.resample_csv(
      text,
      ["x"],
      start_ms=0L,
      end_ms=4L,
      step_ms=1L,
      max_gap_ms=4L,
    ).unwrap()
    for sample in r.recording.samples {
      assert_true(!sample.values[0].is_inf())
    }
    let a = r.recording.samples[0].values[0] / 2.0
    let b = r.recording.samples[4].values[0] / 2.0
    resample_close(r.recording.samples[2].values[0], a + b)
  }
}

///|
test "resample rejects invalid settings and grid counts without integer overflow" {
  for
    (start_ms, end_ms, step_ms, max_gap_ms) in [
      (-1L, 1L, 1L, 1L),
      (1L, 0L, 1L, 1L),
      (0L, 1L, 0L, 1L),
      (0L, 1L, -1L, 1L),
      (0L, 1L, 1L, -1L),
      (0L, 100000L, 1L, 1L),
      (0L, 9223372036854775807L, 1L, 1L),
    ] {
    assert_true(
      @telemetry_csv.resample_csv(
        "timestamp_ms,x\n0,0",
        ["x"],
        start_ms~,
        end_ms~,
        step_ms~,
        max_gap_ms~,
      )
      is Err(_),
    )
  }
  let limit = @telemetry_csv.resample_csv(
    "timestamp_ms,x\n100001,0",
    ["x"],
    start_ms=0L,
    end_ms=99999L,
    step_ms=1L,
    max_gap_ms=0L,
  ).unwrap()
  assert_eq(limit.grid_count, 100000)
  assert_eq(limit.missing.length(), 100000)
}

///|
test "resample rejects missing duplicate empty selection and invalid full input" {
  for channels in [[], ["unknown"], ["x", "x"]] {
    assert_true(
      @telemetry_csv.resample_csv(
        "timestamp_ms,x\n0,0",
        channels,
        start_ms=0L,
        end_ms=0L,
        step_ms=1L,
        max_gap_ms=0L,
      )
      is Err(_),
    )
  }
  for
    text in [
      "timestamp_ms,x,y\n0,0,1\n100,1,NaN", "timestamp_ms,x\n0,0\n0,1", "timestamp_ms,x\n0,0\n10,inf",
      "timestamp_ms,x",
    ] {
    assert_true(
      @telemetry_csv.resample_csv(
        text,
        ["x"],
        start_ms=0L,
        end_ms=0L,
        step_ms=1L,
        max_gap_ms=0L,
      )
      is Err(_),
    )
  }
}

///|
test "resample selected output segment IDs remain stable across a narrow window" {
  let r = @telemetry_csv.resample_csv(
    "timestamp_ms,x\n0,0\n100,1\n1000,10\n1100,11",
    ["x"],
    start_ms=1000L,
    end_ms=1100L,
    step_ms=50L,
    max_gap_ms=100L,
  ).unwrap()
  assert_eq(r.source_segment_count, 2)
  assert_eq(r.output_segment_count, 1)
  assert_eq(r.points[0].source_segment, 1)
  assert_eq(r.to_csv().unwrap(), r.to_csv(segment=1).unwrap())
  assert_true(r.to_csv(segment=0) is Err(_))
}

///|
test "resample CSV composes with existing explorer plot and motion outputs" {
  let r = @telemetry_csv.resample_csv(
    "timestamp_ms,x\n0,0\n150,3\n300,6",
    ["x"],
    start_ms=0L,
    end_ms=300L,
    step_ms=100L,
    max_gap_ms=150L,
  ).unwrap()
  let csv = r.to_csv().unwrap()
  assert_eq(@telemetry_csv.explore_csv(csv).unwrap().sample_count, 4)
  let plot = @telemetry_csv.plot_csv(csv, ["x"], max_gap_ms=100L).unwrap()
  assert_eq(plot.segment_count, 1)
  assert_true(plot.to_svg().contains("<svg"))
  let motion = @telemetry_csv.motion_csv(
    csv,
    ["x"],
    unit_labels=["m"],
    order=1,
    max_gap_ms=100L,
  ).unwrap()
  for sample in motion.recording.samples {
    resample_close(sample.values[0], 20.0)
  }
}
