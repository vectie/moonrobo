///|
fn spectrum_close(
  actual : Double,
  expected : Double,
  tolerance? : Double = 1.0e-10,
) -> Unit raise {
  assert_true(
    (actual - expected).abs() <= tolerance,
    msg="expected \{expected}, got \{actual}",
  )
}

///|
fn spectrum_values(
  values : Array[Double],
  origin? : Int64 = 0L,
  interval? : Int64 = 250L,
) -> @telemetry_csv.TelemetrySpectrum raise {
  let text = StringBuilder()
  text.write_string("timestamp_ms,v\n")
  for i, value in values {
    text.write_string("\{origin + i.to_int64() * interval},\{value}\n")
  }
  guard @telemetry_csv.spectrum_csv(text.to_string(), "v", unit_label="V")
    is Ok(result) else {
    fail("spectrum failed")
  }
  result
}

///|
test "spectrum hand calculated DC Nyquist and quarter-cycle sine normalization" {
  let dc = spectrum_values([3.0, 3.0, 3.0, 3.0])
  spectrum_close(dc.bins[0].amplitude, 3.0)
  spectrum_close(dc.bins[1].amplitude, 0.0)
  spectrum_close(dc.bins[2].amplitude, 0.0)
  assert_eq(dc.sample_interval_ms, 250L)
  assert_eq(dc.sample_rate_hz, 4.0)
  assert_eq(dc.frequency_resolution_hz, 1.0)
  assert_eq(dc.nyquist_hz, 2.0)
  assert_eq(dc.bins.map(b => b.frequency_hz), [0.0, 1.0, 2.0])
  assert_eq(dc.bins.map(b => b.is_nyquist), [false, false, true])
  let nyquist = spectrum_values([2.0, -2.0, 2.0, -2.0])
  spectrum_close(nyquist.bins[2].amplitude, 2.0)
  spectrum_close(nyquist.bins[0].amplitude, 0.0)
  spectrum_close(nyquist.bins[1].amplitude, 0.0)
  let sine = spectrum_values([0.0, 3.0, 0.0, -3.0])
  spectrum_close(sine.bins[1].amplitude, 3.0)
  spectrum_close(sine.bins[0].amplitude, 0.0)
  spectrum_close(sine.bins[2].amplitude, 0.0)
  assert_eq(sine.unit_label, "V")
  assert_eq(sine.frequency_unit, "Hz")
  assert_eq(sine.window, "rectangular")
}

///|
test "spectrum two tones preserve DC and separate known bin amplitudes" {
  let root2 = 2.0.sqrt()
  // 1 + 2*cos(2*pi*n/8) + 3*sin(4*pi*n/8), evaluated by hand.
  let result = spectrum_values(
    [3.0, 4.0 + root2, 1.0, -2.0 - root2, -1.0, 4.0 - root2, 1.0, -2.0 + root2],
    interval=125L,
  )
  for i, expected in [1.0, 2.0, 3.0, 0.0, 0.0] {
    spectrum_close(result.bins[i].amplitude, expected)
  }
  assert_eq(result.frequency_resolution_hz, 1.0)
  assert_eq(result.nyquist_hz, 4.0)
}

///|
test "spectrum odd N doubles its highest non-Nyquist bin and N two stays undoubled" {
  // N=3, cos(2*pi*n/3) is exactly [1,-1/2,-1/2].
  let odd = spectrum_values([1.0, -0.5, -0.5], interval=100L)
  assert_eq(odd.bins.length(), 2)
  assert_false(odd.bins[1].is_nyquist)
  spectrum_close(odd.bins[1].amplitude, 1.0)
  spectrum_close(odd.bins[1].frequency_hz, 10.0 / 3.0)
  assert_eq(odd.nyquist_hz, 5.0)
  let pair = spectrum_values([3.0, -1.0])
  spectrum_close(pair.bins[0].amplitude, 1.0)
  spectrum_close(pair.bins[1].amplitude, 2.0)
  assert_true(pair.bins[1].is_nyquist)
}

///|
test "spectrum demeaning removes selected mean and keeps original values" {
  let text = "timestamp_ms,v\n0,9\n250,12\n500,9\n750,6\n"
  guard @telemetry_csv.spectrum_csv(text, "v", unit_label="V", demean=true)
    is Ok(result) else {
    fail("spectrum failed")
  }
  spectrum_close(result.source_mean, 9.0)
  spectrum_close(result.removed_mean, 9.0)
  spectrum_close(result.bins[0].amplitude, 0.0)
  spectrum_close(result.bins[1].amplitude, 3.0)
  assert_eq(result.samples.map(s => s.value), [9.0, 12.0, 9.0, 6.0])
  assert_true(result.demean)
}

///|
test "spectrum exact large Int64 origins and inclusive subset preserve lineage" {
  let result = spectrum_values(
    [0.0, 3.0, 0.0, -3.0],
    origin=9223372036854775804L,
    interval=1L,
  )
  assert_eq(result.sample_interval_ms, 1L)
  assert_eq(result.sample_rate_hz, 1000.0)
  assert_eq(result.frequency_resolution_hz, 250.0)
  spectrum_close(result.bins[1].amplitude, 3.0)
  assert_eq(result.samples[3].timestamp_ms, 9223372036854775807L)
  guard @telemetry_csv.spectrum_csv(
      "timestamp_ms,v,other\n0,99,3\n10,0,2\n20,2,1\n30,0,0\n40,-2,-1\n91,99,-2\n",
      "v",
      unit_label="V",
      start_ms=10L,
      end_ms=40L,
    )
    is Ok(window) else {
    fail("window failed")
  }
  assert_eq(window.source_sample_count, 6)
  assert_eq(window.samples.map(s => s.source_sample_index), [1, 2, 3, 4])
  assert_eq(window.samples.map(s => s.timestamp_ms), [10L, 20L, 30L, 40L])
  spectrum_close(window.bins[1].amplitude, 2.0)
}

///|
test "spectrum refuses irregular gaps malformed data and invalid selection" {
  for
    text in [
      "timestamp_ms,v\n0,0\n10,1\n21,0\n31,-1\n", "timestamp_ms,v\n0,0\n10,1\n30,0\n40,-1\n",
      "timestamp_ms,v\n0,0\n0,1\n", "timestamp_ms,v\n0,NaN\n1,2\n", "timestamp_ms,v\n1,1\n",
      "timestamp_ms,v\n", "timestamp_ms,v\n-1,1\n0,2\n",
    ] {
    assert_true(
      @telemetry_csv.spectrum_csv(text, "v", unit_label="V") is Err(_),
    )
  }
  let text = "timestamp_ms,v\n0,0\n1,2\n2,0\n3,-2\n"
  assert_true(
    @telemetry_csv.spectrum_csv(text, "absent", unit_label="V") is Err(_),
  )
  assert_true(@telemetry_csv.spectrum_csv(text, "v", unit_label="") is Err(_))
  assert_true(
    @telemetry_csv.spectrum_csv(text, "v", unit_label="\u{0}") is Err(_),
  )
  assert_true(
    @telemetry_csv.spectrum_csv(text, "v", unit_label="V", start_ms=4L)
    is Err(_),
  )
  assert_true(
    @telemetry_csv.spectrum_csv(
      text,
      "v",
      unit_label="V",
      start_ms=3L,
      end_ms=2L,
    )
    is Err(_),
  )
  let many = StringBuilder()
  many.write_string("timestamp_ms,v\n")
  for i in 0..<2049 {
    many.write_string("\{i},1\n")
  }
  assert_true(
    @telemetry_csv.spectrum_csv(many.to_string(), "v", unit_label="V") is Err(_),
  )
}

///|
test "spectrum scaled arithmetic supports finite large DC and reports unrepresentable amplitude" {
  let large = spectrum_values([1.0e308, 1.0e308, 1.0e308, 1.0e308])
  assert_true((large.bins[0].amplitude / 1.0e308 - 1.0).abs() < 1.0e-12)
  let text = "timestamp_ms,v\n0,1.79e308\n1,1.79e308\n2,-1.79e308\n3,-1.79e308\n"
  assert_true(@telemetry_csv.spectrum_csv(text, "v", unit_label="V") is Err(_))
}

///|
test "spectrum SVG shows every bin units normalization and escaped labels" {
  guard @telemetry_csv.spectrum_csv(
      "timestamp_ms,<v>\n0,0\n250,2\n500,0\n750,-2\n",
      "<v>",
      unit_label="V & mV",
    )
    is Ok(result) else {
    fail("spectrum failed")
  }
  let svg = result.to_svg()
  assert_eq(svg.split("class=\"spectrum-bin\"").count(), 4)
  assert_true(svg.contains("&lt;v&gt; [V &amp; mV]"))
  assert_false(svg.contains("<v>"))
  assert_true(svg.contains("Nyquist=2 Hz"))
  assert_true(svg.contains("bin spacing=1 Hz"))
  assert_true(svg.contains("Interior bins doubled"))
  assert_true(svg.contains("Not RMS or PSD"))
  assert_true(result.to_json().stringify().contains("rectangular"))
}
