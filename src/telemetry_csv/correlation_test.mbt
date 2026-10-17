///|
let correlation_fixture : String =
  #|timestamp_ms,command,response,flat
  #|100,2,9,4
  #|110,-1,8,4
  #|120,4,2,4
  #|130,0,-1,4
  #|140,3,4,4
  #|150,-2,0,4
  #|160,5,3,4
  #|170,1,-2,4

///|
test "lag correlation locates shifted relationship with signed original pair lineage" {
  let r = @telemetry_csv.correlation_csv(
    correlation_fixture,
    "command",
    "response",
    max_lag_samples=3,
  ).unwrap()
  assert_eq(r.lags.length(), 7)
  let lag = r.lags[5]
  assert_eq(lag.lag_samples, 2)
  assert_eq(lag.lag_ms, 20L)
  assert_eq(lag.pair_count, 6)
  assert_eq(lag.left_start_sample, 0)
  assert_eq(lag.right_start_sample, 2)
  assert_true((lag.coefficient.unwrap() - 1.0).abs() < 1.0e-12)
  assert_true(r.lags[3].coefficient.unwrap() < 0.9)
  let reverse = @telemetry_csv.correlation_csv(
    correlation_fixture,
    "response",
    "command",
    max_lag_samples=3,
  ).unwrap()
  for i in 0..<7 {
    assert_true(
      (r.lags[i].coefficient.unwrap() - reverse.lags[6 - i].coefficient.unwrap()).abs() <
      1.0e-12,
    )
  }
  assert_eq(r.samples[0].timestamp_ms, 100L)
  assert_eq(r.samples[7].source_sample_index, 7)
}

///|
test "lag correlation constant variance remains undefined in JSON CSV and SVG" {
  let r = @telemetry_csv.correlation_csv(
    correlation_fixture,
    "command",
    "flat",
    max_lag_samples=2,
  ).unwrap()
  assert_true(r.lags.all(lag => lag.coefficient is None))
  assert_true(r.to_csv().contains(",,undefined-zero-or-unresolved-variance"))
  assert_true(r.to_svg().contains("undefined-lag"))
  assert_false(r.to_svg().contains("NaN"))
  assert_false(r.to_svg().contains("correlation-lag\""))
}

///|
test "lag correlation window and exact near-limit timestamps preserve source indices" {
  let text = "timestamp_ms,x,y\n9223372036854775790,1,2\n9223372036854775795,4,8\n9223372036854775800,2,4\n9223372036854775805,3,6\n"
  let r = @telemetry_csv.correlation_csv(
    text,
    "x",
    "y",
    max_lag_samples=0,
    start_ms=9223372036854775795L,
  ).unwrap()
  assert_eq(r.sample_interval_ms, 5L)
  assert_eq(r.samples[0].source_sample_index, 1)
  assert_eq(r.source_sample_count, 4)
  assert_eq(r.lags[0].pair_count, 3)
  assert_true(r.lags[0].coefficient.unwrap() > 0.999999999)
}

///|
test "lag correlation finite large and small scale inputs do not overflow" {
  for
    text in [
      "timestamp_ms,x,y\n0,1e300,-1e300\n1,-1e300,1e300\n2,5e299,-5e299\n", "timestamp_ms,x,y\n0,1e-300,2e-300\n1,3e-300,6e-300\n2,2e-300,4e-300\n",
    ] {
    let r = @telemetry_csv.correlation_csv(text, "x", "y", max_lag_samples=0).unwrap()
    assert_true((r.lags[0].coefficient.unwrap().abs() - 1.0).abs() < 1.0e-12)
  }
}

///|
test "lag correlation refuses irregular gaps malformed tails and invalid bounds" {
  for
    text in [
      "timestamp_ms,x,y\n0,1,2\n1,2,3\n3,3,4\n", "timestamp_ms,x,y\n0,1,2\n1,2,3\n2,3,4\n9,broken,5\n",
      "timestamp_ms,x,y\n0,1,2\n1,2,3\n",
    ] {
    assert_true(
      @telemetry_csv.correlation_csv(
        text,
        "x",
        "y",
        max_lag_samples=0,
        end_ms=3L,
      )
      is Err(_),
    )
  }
  for lag in [-1, 6, 2147483647] {
    assert_true(
      @telemetry_csv.correlation_csv(
        correlation_fixture,
        "command",
        "response",
        max_lag_samples=lag,
      )
      is Err(_),
    )
  }
  assert_true(
    @telemetry_csv.correlation_csv(
      correlation_fixture,
      "missing",
      "response",
      max_lag_samples=0,
    )
    is Err(_),
  )
  assert_true(
    @telemetry_csv.correlation_csv(
      correlation_fixture,
      "command",
      "response",
      max_lag_samples=0,
      start_ms=200L,
      end_ms=100L,
    )
    is Err(_),
  )
}

///|
test "lag correlation identity autocorrelation and safe output" {
  let r = @telemetry_csv.correlation_csv(
    correlation_fixture,
    "command",
    "command",
    max_lag_samples=0,
  ).unwrap()
  assert_true(r.lags[0].coefficient.unwrap() > 0.999999999)
  assert_true(r.to_csv().has_prefix("lag_samples,lag_ms,pair_count"))
  assert_true(r.to_svg().contains("cx=\"565"))
  let escaped = @telemetry_csv.correlation_csv(
      "timestamp_ms,<signal>,other\n0,1,2\n1,3,6\n2,2,4",
      "<signal>",
      "other",
      max_lag_samples=0,
    )
    .unwrap()
    .to_svg()
  assert_true(escaped.contains("&lt;signal&gt;"))
  assert_false(escaped.contains("<signal>"))
}
