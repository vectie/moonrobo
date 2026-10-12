///|
fn degrees() -> Array[@telemetry_csv.PeriodicChannel] {
  [{ source: "q", target: "continuous", period: 360.0, unit: "deg", }]
}

///|
test "unwrap forward reverse crossings and retain other channels in place" {
  let result = @telemetry_csv.unwrap_csv(
    "timestamp_ms,q,temperature\n0,170,20\n100,179,21\n200,-172,22\n300,-163,23\n400,-172,24\n500,179,25",
    degrees(),
    max_gap_ms=100L,
  ).unwrap()
  assert_eq(result.recording.channels, ["continuous", "temperature"])
  assert_eq(result.recording.samples.map(s => s.values[0]), [
    170.0, 179.0, 188.0, 197.0, 188.0, 179.0,
  ])
  assert_eq(result.recording.samples.map(s => s.values[1]), [
    20.0, 21.0, 22.0, 23.0, 24.0, 25.0,
  ])
  assert_eq(result.points[2].source_values, [-172.0])
  assert_eq(result.points[2].step_adjustments, [360.0])
  assert_eq(result.points[3].step_adjustments, [0.0])
  assert_eq(result.points[4].offsets, [360.0])
  assert_eq(result.points[5].step_adjustments, [-360.0])
  assert_eq(result.points[5].offsets, [0.0])
  assert_eq(result.segment_count, 1)
  assert_true(result.points[0].segment_start)
  assert_true(!result.points[1].segment_start)
}

///|
test "unwrap independent periods and recipe order preserve original column order" {
  let result = @telemetry_csv.unwrap_csv(
    "timestamp_ms,q,encoder\n0,170,10\n100,-170,4090\n200,-150,4070",
    [
      { source: "encoder", target: "ticks", period: 4096.0, unit: "count", },
      { source: "q", target: "degrees", period: 360.0, unit: "deg", },
    ],
    max_gap_ms=100L,
  ).unwrap()
  assert_eq(result.recording.channels, ["degrees", "ticks"])
  assert_eq(result.recording.samples[1].values, [190.0, -6.0])
  assert_eq(result.recording.samples[2].values, [210.0, -26.0])
  assert_eq(result.points[1].source_values, [4090.0, -170.0])
  assert_eq(result.points[1].offsets, [-4096.0, 360.0])
  assert_eq(result.channels[0].unit, "count")
}

///|
test "unwrap resets offsets across gaps and accepts gap cutoff equality" {
  let result = @telemetry_csv.unwrap_csv(
    "timestamp_ms,q\n0,170\n100,-170\n1000,-170\n1100,170\n9999,20",
    degrees(),
    max_gap_ms=100L,
  ).unwrap()
  assert_eq(result.recording.samples.map(s => s.values[0]), [
    170.0, 190.0, -170.0, -190.0, 20.0,
  ])
  assert_eq(result.points.map(p => p.segment), [0, 0, 1, 1, 2])
  assert_eq(result.points.map(p => p.segment_start), [
    true, false, true, false, true,
  ])
  assert_eq(result.points[2].offsets, [0.0])
  assert_eq(result.points[4].step_adjustments, [0.0])
  assert_eq(result.segment_count, 3)
  assert_eq(result.gaps[0].duration_ms, 900L)
  assert_eq(result.gaps[0].left_sample_index, 1)
  assert_eq(result.gaps[0].right_timestamp_ms, 1000L)
  assert_eq(result.gaps[1].duration_ms, 8899L)
}

///|
test "unwrap half-period ties keep raw sign and report ambiguity" {
  let result = @telemetry_csv.unwrap_csv(
    "timestamp_ms,q\n0,0\n1,180\n2,0\n3,540\n4,0\n5,360\n6,0",
    degrees(),
    max_gap_ms=1L,
  ).unwrap()
  assert_eq(result.recording.samples.map(s => s.values[0]), [
    0.0, 180.0, 0.0, 180.0, 0.0, 0.0, 0.0,
  ])
  assert_eq(result.points.map(p => p.half_period_ties[0]), [
    false, true, true, true, true, false, false,
  ])
  assert_eq(result.points[3].step_adjustments, [-360.0])
  assert_eq(result.points[4].step_adjustments, [360.0])
}

///|
test "unwrap radians nonunit period and no boundary origin assumption" {
  let pi = 3.141592653589793
  let result = @telemetry_csv.unwrap_csv(
    "timestamp_ms,q\n0,3.0\n1,-3.0\n2,-2.8",
    [{ source: "q", target: "q", period: 2.0 * pi, unit: "rad", }],
    max_gap_ms=1L,
  ).unwrap()
  assert_true(
    (result.recording.samples[1].values[0] - (2.0 * pi - 3.0)).abs() < 1.0e-12,
  )
  let shifted = @telemetry_csv.unwrap_csv(
    "timestamp_ms,q\n0,109\n1,101\n2,103",
    [{ source: "q", target: "q", period: 10.0, unit: "phase", }],
    max_gap_ms=1L,
  ).unwrap()
  assert_eq(shifted.recording.samples.map(s => s.values[0]), [
    109.0, 111.0, 113.0,
  ])
}

///|
test "unwrap singletons and stationary observations are retained" {
  for text in ["timestamp_ms,q\n0,8", "timestamp_ms,q\n0,8\n1,8\n2,8"] {
    let result = @telemetry_csv.unwrap_csv(text, degrees(), max_gap_ms=1L).unwrap()
    for sample in result.recording.samples {
      assert_eq(sample.values[0], 8.0)
    }
    for point in result.points {
      assert_eq(point.offsets, [0.0])
    }
    assert_true(result.to_csv() is Ok(_))
  }
}

///|
test "unwrap CSV composes with motion and plot without wrap spikes" {
  let text = "timestamp_ms,q\n0,170\n100,179\n200,-172\n300,-163\n1400,-170\n1500,-179\n1600,172\n1700,163"
  let result = @telemetry_csv.unwrap_csv(text, degrees(), max_gap_ms=100L).unwrap()
  let csv = result.to_csv().unwrap()
  let rate = @telemetry_csv.motion_csv(
    csv,
    ["continuous"],
    unit_labels=["deg"],
    order=1,
    max_gap_ms=100L,
  ).unwrap()
  assert_eq(rate.recording.samples.map(s => s.values[0]), [
    90.0, 90.0, 90.0, -90.0, -90.0, -90.0,
  ])
  let acceleration = @telemetry_csv.motion_csv(
    csv,
    ["continuous"],
    unit_labels=["deg"],
    order=2,
    max_gap_ms=100L,
  ).unwrap()
  assert_eq(acceleration.recording.samples.length(), 4)
  for sample in acceleration.recording.samples {
    assert_eq(sample.values[0], 0.0)
  }
  let plot = @telemetry_csv.plot_csv(
    csv,
    ["continuous"],
    unit_labels=["deg"],
    max_gap_ms=100L,
  ).unwrap()
  assert_eq(plot.segment_count, 2)
  assert_eq(plot.gap_count, 1)
  assert_true(plot.to_svg().contains("deg"))
}

///|
test "unwrap preserves exact Int64 timestamps and huge gap spans" {
  let result = @telemetry_csv.unwrap_csv(
    "timestamp_ms,q\n9007199254740993,170\n9007199254740994,-170\n9223372036854775807,179",
    degrees(),
    max_gap_ms=1L,
  ).unwrap()
  assert_eq(result.recording.samples[1].timestamp_ms, 9007199254740994L)
  assert_eq(result.recording.samples[2].values[0], 179.0)
  assert_eq(result.gaps[0].duration_ms, 9214364837600034813L)
  assert_true(result.to_csv().unwrap().contains("9007199254740993,"))
}

///|
test "unwrap strict recipes reject missing unknown duplicate and invalid fields" {
  let valid = "[{\"source\":\"q\",\"target\":\"u\",\"period\":360,\"unit\":\"deg\"}]"
  assert_eq(@telemetry_csv.parse_unwrap_recipe(valid).unwrap()[0].period, 360.0)
  for
    text in [
      "[]", "{}", "bad", "[1]", "[{\"source\":\"q\",\"target\":\"u\",\"period\":360}]",
      "[{\"source\":\"q\",\"target\":\"u\",\"period\":360,\"unknown\":\"deg\"}]",
      "[{\"source\":\"q\",\"target\":\"u\",\"period\":360,\"unit\":\"deg\",\"extra\":0}]",
      "[{\"source\":\"q\",\"target\":\"u\",\"period\":360,\"unit\":\"deg\",\"unit\":\"rad\"}]",
      "[{\"source\":\"q\",\"target\":\"u\",\"period\":360,\"unit\":\"deg\",\"\\u0075nit\":\"rad\"}]",
      "[{\"source\":\"q\",\"target\":\"u\",\"period\":\"360\",\"unit\":\"deg\"}]",
    ] {
    assert_true(@telemetry_csv.parse_unwrap_recipe(text) is Err(_))
  }
}

///|
test "unwrap validates API recipe options and simultaneous rename collisions" {
  let text = "timestamp_ms,q,other\n0,170,0\n1,-170,1"
  for period in [0.0, -1.0, 1.0 / 0.0, 0.0 / 0.0, 5.0e-324] {
    assert_true(
      @telemetry_csv.unwrap_csv(
        text,
        [{ source: "q", target: "u", period, unit: "deg", }],
        max_gap_ms=1L,
      )
      is Err(_),
    )
  }
  let invalid : Array[@telemetry_csv.PeriodicChannel] = [
    { source: "missing", target: "u", period: 360.0, unit: "deg", },
    { source: "q", target: "other", period: 360.0, unit: "deg", },
    { source: "q", target: "timestamp_ms", period: 360.0, unit: "deg", },
    { source: "q", target: "bad,name", period: 360.0, unit: "deg", },
    { source: "q", target: " u", period: 360.0, unit: "deg", },
    { source: "q", target: "u", period: 360.0, unit: " ", },
  ]
  for mapping in invalid {
    assert_true(
      @telemetry_csv.unwrap_csv(text, [mapping], max_gap_ms=1L) is Err(_),
    )
  }
  assert_true(@telemetry_csv.unwrap_csv(text, [], max_gap_ms=1L) is Err(_))
  assert_true(
    @telemetry_csv.unwrap_csv(text, [degrees()[0], degrees()[0]], max_gap_ms=1L)
    is Err(_),
  )
  for gap in [0L, -1L] {
    assert_true(
      @telemetry_csv.unwrap_csv(text, degrees(), max_gap_ms=gap) is Err(_),
    )
  }
  let swap = @telemetry_csv.unwrap_csv(
    text,
    [
      { source: "q", target: "other", period: 360.0, unit: "deg", },
      { source: "other", target: "q", period: 10.0, unit: "phase", },
    ],
    max_gap_ms=1L,
  ).unwrap()
  assert_eq(swap.recording.channels, ["other", "q"])
  assert_eq(swap.recording.samples[1].values, [190.0, 1.0])
}

///|
test "unwrap validates late unused data and rejects nonfinite arithmetic" {
  for
    text in [
      "timestamp_ms,q,unused\n0,0,0\n1,1,bad", "timestamp_ms,q\n0,1\n0,2", "timestamp_ms,q\n2,1\n1,2",
      "timestamp_ms,q\n-1,1", "timestamp_ms,q\n0,1\n10,NaN", "timestamp_ms,q\n0,1\n10,1e999",
      "timestamp_ms,q\n0,1\n10,1,2", "timestamp_ms,q\n0,-1e308\n1,1e308",
    ] {
    assert_true(
      @telemetry_csv.unwrap_csv(text, degrees(), max_gap_ms=1L) is Err(_),
    )
  }
}

///|
test "unwrap hidden turns are ambiguous shortest-path estimates not recovered observations" {
  let result = @telemetry_csv.unwrap_csv(
    "timestamp_ms,q\n0,0\n1,300\n2,660",
    degrees(),
    max_gap_ms=1L,
  ).unwrap()
  assert_eq(result.recording.samples.map(s => s.values[0]), [0.0, -60.0, -60.0])
  assert_true(result.assumption.contains("hidden turns are not recoverable"))
  assert_eq(result.points[2].step_adjustments, [-360.0])
}
