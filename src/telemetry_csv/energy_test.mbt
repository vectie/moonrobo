///|
fn energy_close(actual : Double, expected : Double) -> Unit raise {
  assert_true((actual - expected).abs() <= 1.0e-11 * expected.abs().max(1.0))
}

///|
test "energy constant load integrates elapsed duration rather than sample count" {
  let r = @telemetry_csv.energy_csv(
    "timestamp_ms,v,i,unused\n100,12,2,8\n1100,12,2,9\n3600100,12,2,10",
    "v",
    "i",
    current_polarity="discharge-positive",
    max_gap_ms=3600000L,
  ).unwrap()
  energy_close(r.drawn_wh, 24.0)
  assert_eq(r.recovered_wh, 0.0)
  energy_close(r.net_wh, 24.0)
  assert_eq(r.integrated_duration_ms, 3600000L)
  assert_eq(r.excluded_duration_ms, 0L)
  assert_eq(r.supported_interval_count, 2)
  assert_eq(r.points[1].source_sample_index, 1)
  assert_eq(r.points[1].voltage_v, 12.0)
  assert_eq(r.points[1].current_a, 2.0)
  assert_eq(r.recording.samples[0].values, [24.0, 0.0, 0.0, 0.0])
}

///|
test "energy reversed current convention yields identical power and totals" {
  let positive = @telemetry_csv.energy_csv(
    "timestamp_ms,v,i\n0,12,2\n1000,10,-1\n3000,10,1",
    "v",
    "i",
    current_polarity="discharge-positive",
    max_gap_ms=2000L,
  ).unwrap()
  let negative = @telemetry_csv.energy_csv(
    "timestamp_ms,i,v\n0,-2,12\n1000,1,10\n3000,-1,10",
    "v",
    "i",
    current_polarity="charge-positive",
    max_gap_ms=2000L,
  ).unwrap()
  assert_eq(positive.recording, negative.recording)
  assert_eq(positive.intervals, negative.intervals)
  assert_eq(positive.points[0].current_a, 2.0)
  assert_eq(negative.points[0].current_a, -2.0)
}

///|
test "energy splits unequal opposite powers at modeled zero in both directions" {
  for currents in ["0,10,3\n3600000,10,-1", "0,10,-3\n3600000,10,1"] {
    let r = @telemetry_csv.energy_csv(
      "timestamp_ms,v,i\n" + currents,
      "v",
      "i",
      current_polarity="discharge-positive",
      max_gap_ms=3600000L,
    ).unwrap()
    assert_eq(r.intervals[0].zero_crossing_fraction, Some(0.75))
    if r.points[0].power_w > 0.0 {
      energy_close(r.drawn_wh, 11.25)
      energy_close(r.recovered_wh, 1.25)
      energy_close(r.net_wh, 10.0)
    } else {
      energy_close(r.drawn_wh, 1.25)
      energy_close(r.recovered_wh, 11.25)
      energy_close(r.net_wh, -10.0)
    }
  }
}

///|
test "energy constant recovery zero endpoints and all zero power" {
  let r = @telemetry_csv.energy_csv(
    "timestamp_ms,v,i\n0,10,0\n3600000,10,-2\n7200000,10,-2\n10800000,0,8",
    "v",
    "i",
    current_polarity="discharge-positive",
    max_gap_ms=3600000L,
  ).unwrap()
  assert_eq(r.drawn_wh, 0.0)
  energy_close(r.recovered_wh, 40.0)
  for interval in r.intervals {
    assert_eq(interval.zero_crossing_fraction, None)
  }
  let zero = @telemetry_csv.energy_csv(
    "timestamp_ms,v,i\n0,0,5\n1000,1,0",
    "v",
    "i",
    current_polarity="discharge-positive",
    max_gap_ms=1000L,
  ).unwrap()
  assert_eq(zero.net_wh, 0.0)
  assert_eq(zero.integrated_duration_ms, 1000L)
}

///|
test "energy gaps exclude unsupported duration and resume observation sums" {
  let r = @telemetry_csv.energy_csv(
    "timestamp_ms,v,i\n0,10,1\n1000,10,1\n10000,10,-1\n11000,10,-1",
    "v",
    "i",
    current_polarity="discharge-positive",
    max_gap_ms=1000L,
  ).unwrap()
  assert_eq(r.segment_count, 2)
  assert_eq(r.supported_interval_count, 2)
  assert_eq(r.integrated_duration_ms, 2000L)
  assert_eq(r.excluded_duration_ms, 9000L)
  assert_eq(r.points.map(p => p.segment_start), [true, false, true, false])
  assert_eq(r.points.map(p => p.segment), [0, 0, 1, 1])
  assert_eq(r.gaps[0].left_sample_index, 1)
  assert_eq(r.gaps[0].right_timestamp_ms, 10000L)
  assert_eq(r.intervals[1].left_sample_index, 2)
  assert_eq(r.intervals[1].segment, 1)
  assert_eq(r.recording.samples[1].values[1], r.recording.samples[2].values[1])
  energy_close(r.drawn_wh, 10.0 / 3600.0)
  energy_close(r.recovered_wh, 10.0 / 3600.0)
  assert_eq(r.net_wh, 0.0)
}

///|
test "energy singleton and entirely isolated points have no integrated coverage" {
  for
    text in ["timestamp_ms,v,i\n50,10,2", "timestamp_ms,v,i\n50,10,2\n100,10,2"] {
    let r = @telemetry_csv.energy_csv(
      text,
      "v",
      "i",
      current_polarity="discharge-positive",
      max_gap_ms=1L,
    ).unwrap()
    assert_eq(r.integrated_duration_ms, 0L)
    assert_eq(r.supported_interval_count, 0)
    assert_eq(r.drawn_wh, 0.0)
    assert_eq(r.recovered_wh, 0.0)
    assert_eq(r.segment_count, r.source_sample_count)
    assert_true(r.to_csv() is Ok(_))
  }
}

///|
test "energy linear sample power differs from interpolated voltage times current" {
  let r = @telemetry_csv.energy_csv(
    "timestamp_ms,v,i\n0,0,0\n3600000,2,2",
    "v",
    "i",
    current_polarity="discharge-positive",
    max_gap_ms=3600000L,
  ).unwrap()
  assert_eq(r.drawn_wh, 2.0)
  // Interpolating both channels would yield 4/3 Wh: that is not this model.
  assert_true((r.drawn_wh - 4.0 / 3.0).abs() > 0.6)
}

///|
test "energy millisecond durations remain exact above Double epoch precision" {
  let r = @telemetry_csv.energy_csv(
    "timestamp_ms,v,i\n9007199254740993,3600,1\n9007199254740994,3600,1\n9007199254740996,3600,1",
    "v",
    "i",
    current_polarity="discharge-positive",
    max_gap_ms=2L,
  ).unwrap()
  assert_eq(r.integrated_duration_ms, 3L)
  assert_eq(r.intervals[0].duration_ms, 1L)
  energy_close(r.drawn_wh, 0.003)
  assert_true(r.to_csv().unwrap().contains("9007199254740994,"))
}

///|
test "energy full Int64 span splits coverage without overflowing durations" {
  let r = @telemetry_csv.energy_csv(
    "timestamp_ms,v,i\n0,1,0\n1,1,0\n9223372036854775807,1,0",
    "v",
    "i",
    current_polarity="discharge-positive",
    max_gap_ms=1L,
  ).unwrap()
  assert_eq(r.integrated_duration_ms, 1L)
  assert_eq(r.excluded_duration_ms, 9223372036854775806L)
  assert_eq(r.net_wh, 0.0)
}

///|
test "energy stable trapezoids avoid unnecessary same-sign and opposite-sign overflow" {
  let same = @telemetry_csv.energy_csv(
    "timestamp_ms,v,i\n0,1,1e308\n1,1,1e308",
    "v",
    "i",
    current_polarity="discharge-positive",
    max_gap_ms=1L,
  ).unwrap()
  assert_true(!same.drawn_wh.is_inf())
  energy_close(same.drawn_wh / 1.0e308, 1.0 / 3600000.0)
  let crossing = @telemetry_csv.energy_csv(
    "timestamp_ms,v,i\n0,1,1e308\n1,1,-1e308",
    "v",
    "i",
    current_polarity="discharge-positive",
    max_gap_ms=1L,
  ).unwrap()
  assert_eq(crossing.intervals[0].zero_crossing_fraction, Some(0.5))
  assert_eq(crossing.net_wh, 0.0)
  assert_true(crossing.drawn_wh > 0.0 && !crossing.drawn_wh.is_inf())
  let unequal = @telemetry_csv.energy_csv(
    "timestamp_ms,v,i\n0,1,1e300\n3600000,1,-1e280",
    "v",
    "i",
    current_polarity="discharge-positive",
    max_gap_ms=3600000L,
  ).unwrap()
  // Compute both fractions directly: 1 - a/(a+b) would round to zero here.
  energy_close(unequal.recovered_wh / 1.0e260, 0.5)
}

///|
test "energy rejects invalid selection policy and values including unused columns" {
  let good = "timestamp_ms,v,i\n0,12,1"
  for polarity in ["", "auto", "positive"] {
    assert_true(
      @telemetry_csv.energy_csv(
        good,
        "v",
        "i",
        current_polarity=polarity,
        max_gap_ms=1L,
      )
      is Err(_),
    )
  }
  for gap in [0L, -1L] {
    assert_true(
      @telemetry_csv.energy_csv(
        good,
        "v",
        "i",
        current_polarity="discharge-positive",
        max_gap_ms=gap,
      )
      is Err(_),
    )
  }
  for (v, i) in [("missing", "i"), ("v", "missing"), ("v", "v")] {
    assert_true(
      @telemetry_csv.energy_csv(
        good,
        v,
        i,
        current_polarity="discharge-positive",
        max_gap_ms=1L,
      )
      is Err(_),
    )
  }
  for
    text in [
      "timestamp_ms,v,i\n0,-1,2", "timestamp_ms,v,i\n0,1e308,1e308", "timestamp_ms,v,i,u\n0,12,1,0\n1,12,1,NaN",
      "timestamp_ms,v,i\n0,12,1\n0,12,2", "timestamp_ms,v,i\n0,12,1\n1,12",
    ] {
    assert_true(
      @telemetry_csv.energy_csv(
        text,
        "v",
        "i",
        current_polarity="discharge-positive",
        max_gap_ms=1L,
      )
      is Err(_),
    )
  }
}

///|
test "energy rejects interval and cumulative overflow instead of partial exports" {
  for
    text in [
      "timestamp_ms,v,i\n0,1,1e308\n9223372036854775807,1,1e308", "timestamp_ms,v,i\n0,1,1e308\n3600000,1,1e308\n7200000,1,1e308",
    ] {
    assert_true(
      @telemetry_csv.energy_csv(
        text,
        "v",
        "i",
        current_polarity="discharge-positive",
        max_gap_ms=9223372036854775807L,
      )
      is Err(_),
    )
  }
}

///|
test "energy CSV composes with observation explorer and gap aware plot" {
  let r = @telemetry_csv.energy_csv(
    "timestamp_ms,v,i\n10,12,2\n1010,12,-2\n5010,12,1\n6010,12,1",
    "v",
    "i",
    current_polarity="discharge-positive",
    max_gap_ms=1000L,
  ).unwrap()
  let csv = r.to_csv().unwrap()
  let explored = @telemetry_csv.explore_csv(csv).unwrap()
  assert_eq(explored.sample_count, 4)
  assert_eq(explored.channels, [
    "power.w", "observed.drawn.wh", "observed.recovered.wh", "observed.net.wh",
  ])
  assert_eq(explored.samples.map(s => s.timestamp_ms), [
    10L, 1010L, 5010L, 6010L,
  ])
  let plot = @telemetry_csv.plot_csv(
    csv,
    ["power.w"],
    unit_labels=["W"],
    max_gap_ms=1000L,
  ).unwrap()
  assert_eq(plot.segment_count, 2)
  assert_eq(plot.gap_count, 1)
  assert_true(plot.to_svg().contains("W"))
}
