///|
test "strict predicates split at equality and preserve positions and extrema" {
  let text = "timestamp_ms,temp,other\n0,5,0\n10,7,0\n20,9,0\n30,5,0\n40,8,0\n50,4,0\n60,3,0\n"
  let result = @telemetry_csv.threshold_events_csv(text, "temp", "above", 5).unwrap()
  assert_eq(result.source_sample_count, 7)
  assert_eq(result.episodes.length(), 2)
  let first = result.episodes[0]
  assert_eq(first.first_timestamp_ms, 10L)
  assert_eq(first.last_timestamp_ms, 20L)
  assert_eq(first.first_sample_position, 1)
  assert_eq(first.last_sample_position, 2)
  assert_eq(first.observed_span_ms, 10L)
  assert_eq(first.sample_count, 2)
  assert_eq(first.minimum, 7.0)
  assert_eq(first.maximum, 9.0)
  assert_eq(result.episodes[1].sample_count, 1)
  assert_eq(result.episodes[1].observed_span_ms, 0L)
  let below = @telemetry_csv.threshold_events_csv(text, "temp", "below", 5).unwrap()
  assert_eq(below.episodes.length(), 1)
  assert_eq(below.episodes[0].first_sample_position, 5)
  assert_eq(below.episodes[0].last_sample_position, 6)
}

///|
test "gap and span boundaries are inclusive and never bridge nonmatches" {
  let text = "timestamp_ms,v\n0,2\n10,3\n21,4\n31,5\n32,0\n33,6\n"
  let result = @telemetry_csv.threshold_events_csv(
    text,
    "v",
    "above",
    1,
    max_gap_ms=10L,
  ).unwrap()
  assert_eq(result.episodes.length(), 3)
  assert_eq(result.episodes[0].sample_count, 2)
  assert_eq(result.episodes[1].first_sample_position, 2)
  assert_eq(result.episodes[1].sample_count, 2)
  assert_eq(
    @telemetry_csv.threshold_events_csv(
      text,
      "v",
      "above",
      1,
      max_gap_ms=10L,
      min_span_ms=10L,
    ).unwrap().episodes.length(),
    2,
  )
  assert_eq(
    @telemetry_csv.threshold_events_csv(
      text,
      "v",
      "above",
      1,
      max_gap_ms=10L,
      min_span_ms=11L,
    ).unwrap().episodes.length(),
    0,
  )
  assert_eq(
    @telemetry_csv.threshold_events_csv(text, "v", "above", 1, max_gap_ms=0L).unwrap().episodes.length(),
    5,
  )
}

///|
test "empty and singleton results are valid and deterministic" {
  let text = "timestamp_ms,v\n0,5\n"
  let empty = @telemetry_csv.threshold_events_csv(text, "v", "above", 5).unwrap()
  assert_eq(empty.episodes.length(), 0)
  assert_eq(empty.to_csv().split("\n").collect().length(), 2)
  let singleton = @telemetry_csv.threshold_events_csv(text, "v", "below", 6).unwrap()
  assert_eq(singleton.episodes[0].sample_count, 1)
  assert_eq(
    singleton,
    @telemetry_csv.threshold_events_csv(text, "v", "below", 6).unwrap(),
  )
  assert_eq(
    @telemetry_csv.threshold_events_csv(text, "v", "below", 6, min_span_ms=1L).unwrap().episodes.length(),
    0,
  )
}

///|
test "Int64 endpoints and maximum span remain exact in JSON and CSV" {
  let text = "timestamp_ms,v\n0,2\n9007199254740993,3\n9223372036854775807,4\n"
  let result = @telemetry_csv.threshold_events_csv(
    text,
    "v",
    "above",
    1,
    min_span_ms=9223372036854775807L,
  ).unwrap()
  assert_eq(result.episodes.length(), 1)
  assert_eq(result.episodes[0].observed_span_ms, 9223372036854775807L)
  assert_true(
    result
    .to_json()
    .stringify()
    .contains("\"last_timestamp_ms\":\"9223372036854775807\""),
  )
  assert_true(
    result
    .to_csv()
    .contains(",0,9223372036854775807,0,2,9223372036854775807,3,2,4"),
  )
  let singles = @telemetry_csv.threshold_events_csv(
    text,
    "v",
    "above",
    1,
    max_gap_ms=0L,
  ).unwrap()
  assert_true(
    singles
    .to_json()
    .stringify()
    .contains("\"first_timestamp_ms\":\"9007199254740993\""),
  )
  assert_true(singles.to_csv().contains(",9007199254740993,9007199254740993,"))
}

///|
test "full input validation including late unused channels and bad options" {
  for
    text in [
      "timestamp_ms,v,other\n0,0,1\n1,0,NaN\n", "timestamp_ms,v,other\n0,0,1\n1,0,Infinity\n",
      "timestamp_ms,v\n0,0\n0,0\n", "timestamp_ms,v\n-1,0\n", "timestamp_ms,v\n9223372036854775808,0\n",
      "timestamp_ms,v\n0,0\n1\n", "timestamp_ms,v,v\n0,0,0\n", "timestamp_ms,v\n",
      "timestamp_ms,v\n0,\"0\"\n",
    ] {
    assert_true(
      @telemetry_csv.threshold_events_csv(text, "v", "above", 1) is Err(_),
    )
  }
  let text = "timestamp_ms,v\n0,2\n"
  assert_true(
    @telemetry_csv.threshold_events_csv(text, "absent", "above", 1) is Err(_),
  )
  assert_true(
    @telemetry_csv.threshold_events_csv(text, "v", "equal", 1) is Err(_),
  )
  assert_true(
    @telemetry_csv.threshold_events_csv(text, "v", "above", 1, min_span_ms=-1L)
    is Err(_),
  )
  assert_true(
    @telemetry_csv.threshold_events_csv(text, "v", "above", 1, max_gap_ms=-1L)
    is Err(_),
  )
  assert_true(
    @telemetry_csv.threshold_events_csv(text, "v", "above", 0.0 / 0.0) is Err(_),
  )
  assert_true(
    @telemetry_csv.threshold_events_csv(text, "v", "above", 1.0 / 0.0) is Err(_),
  )
}

///|
test "finite extremes require no overflowing value arithmetic" {
  let result = @telemetry_csv.threshold_events_csv(
    "timestamp_ms,v\n0,-1.0e308\n1,1.0e308\n", "v", "above", -1.1e308,
  ).unwrap()
  assert_eq(result.episodes[0].minimum, -1.0e308)
  assert_eq(result.episodes[0].maximum, 1.0e308)
}

///|
test "blank lines CRLF and labels preserve sample positions" {
  let text = "\r\ntimestamp_ms,temperature C\r\n\r\n10,0\r\n\r\n20,2\r\n30,3\r\n"
  let result = @telemetry_csv.threshold_events_csv(
    text, "temperature C", "above", 1,
  ).unwrap()
  assert_eq(result.source_sample_count, 3)
  assert_eq(result.episodes[0].first_sample_position, 1)
  assert_eq(result.episodes[0].last_sample_position, 2)
  assert_true(result.to_csv().contains("\"temperature C\",above,1,"))
}
