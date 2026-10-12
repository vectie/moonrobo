///|
fn mapping(
  source : String,
  target : String,
  scale? : Double = 1.0,
  offset? : Double = 0.0,
) -> @telemetry_csv.ChannelMapping {
  { source, target, scale, offset, source_unit: "raw", target_unit: "chosen", }
}

///|
test "normalization preserves exact timestamps order unmapped values and provenance" {
  let text = "timestamp_ms,y_cm,temp_F,x_cm\n9007199254740993,200,32,100\n9223372036854775807,400,212,300"
  let mappings = [
    mapping("x_cm", "x", scale=0.01),
    mapping("y_cm", "y", scale=0.01),
    {
      source: "temp_F",
      target: "temperature",
      scale: 5.0 / 9.0,
      offset: -160.0 / 9.0,
      source_unit: "user F",
      target_unit: "user C",
    },
  ]
  let result = @telemetry_csv.normalize_csv(text, mappings).unwrap()
  assert_eq(result.recording.channels, ["y", "temperature", "x"])
  assert_eq(result.recording.samples[0].timestamp_ms, 9007199254740993L)
  assert_eq(result.recording.samples[1].timestamp_ms, 9223372036854775807L)
  assert_eq(result.recording.samples[0].values, [2.0, 0.0, 1.0])
  assert_true((result.recording.samples[1].values[1] - 100.0).abs() < 0.0000001)
  assert_eq(result.channels[1].source_unit, Some("user F"))
  assert_eq(result.channels[1].target_unit, Some("user C"))
  assert_eq(result.channels[0].source, "y_cm")
  assert_eq(
    @telemetry_csv.parse(result.to_csv().unwrap()).unwrap(),
    result.recording,
  )
  let passthrough = @telemetry_csv.normalize_csv(text, [mapping("x_cm", "x")]).unwrap()
  assert_eq(passthrough.channels[0].source_unit, None)
  assert_true(!passthrough.channels[0].explicitly_mapped)
  assert_eq(passthrough.recording.samples[1].values, [400.0, 212.0, 300.0])
}

///|
test "simultaneous swaps identity and zero or negative scales are explicit" {
  let text = "timestamp_ms,a,b\n0,2,7\n1,3,8"
  let swapped = @telemetry_csv.normalize_csv(text, [
    mapping("a", "b", scale=-2.0, offset=1.0),
    mapping("b", "a", scale=0.0, offset=5.0),
  ]).unwrap()
  assert_eq(swapped.recording.channels, ["b", "a"])
  assert_eq(swapped.recording.samples[0].values, [-3.0, 5.0])
  assert_eq(
    @telemetry_csv.normalize_csv(text, []).unwrap().recording,
    @telemetry_csv.parse(text).unwrap(),
  )
}

///|
test "normalization rejects duplicate sources final collisions missing channels and bad names" {
  let text = "timestamp_ms,a,b\n0,1,2"
  for
    mappings in [
      [mapping("a", "b")],
      [mapping("a", "c"), mapping("b", "c")],
      [mapping("a", "c"), mapping("a", "d")],
      [mapping("absent", "c")],
    ] {
    assert_true(@telemetry_csv.normalize_csv(text, mappings) is Err(_))
  }
  for name in ["", "timestamp_ms", " a", "a ", "a,b", "a\nb", "a\rb", "a\"b"] {
    assert_true(
      @telemetry_csv.normalize_csv(text, [mapping("a", name)]) is Err(_),
    )
  }
}

///|
test "finite coefficients and transformed results required including unused raw channels" {
  let text = "timestamp_ms,a\n0,1\n1,1e308"
  assert_true(
    @telemetry_csv.normalize_csv(text, [mapping("a", "a", scale=2.0)]) is Err(_),
  )
  assert_true(
    @telemetry_csv.normalize_csv(text, [mapping("a", "a", offset=1.0e308)])
    is Err(_),
  )
  for value in [1.0 / 0.0, -1.0 / 0.0, 0.0 / 0.0] {
    assert_true(
      @telemetry_csv.normalize_csv(text, [mapping("a", "a", scale=value)])
      is Err(_),
    )
    assert_true(
      @telemetry_csv.normalize_csv(text, [mapping("a", "a", offset=value)])
      is Err(_),
    )
  }
  for
    bad in [
      "timestamp_ms,a,b\n0,1,NaN", "timestamp_ms,a\n0,1\n0,2", "timestamp_ms,a\n-1,2",
      "timestamp_ms,a\n0,1\n1,garbage", "timestamp_ms,a",
    ] {
    assert_true(@telemetry_csv.normalize_csv(bad, []) is Err(_))
  }
}

///|
test "recipe JSON validates field shape and keeps exact supplied labels" {
  let recipe = @telemetry_csv.parse_normalization_recipe(
    "[{\"source\":\"a\",\"target\":\"α.m\",\"scale\":0.01,\"offset\":1,\"source_unit\":\" cm \",\"target_unit\":\"m\\nlabel\"}]",
  ).unwrap()
  let result = @telemetry_csv.normalize_csv("timestamp_ms,a\n0,100", recipe).unwrap()
  assert_eq(result.channels[0].source_unit, Some(" cm "))
  assert_eq(result.channels[0].target_unit, Some("m\nlabel"))
  assert_eq(result.recording.samples[0].values, [2.0])
  for
    bad in [
      "not json", "{}", "[1]", "[{\"source\":\"a\"}]", "[{\"source\":\"a\",\"target\":\"b\",\"scale\":\"1\",\"offset\":0,\"source_unit\":\"x\",\"target_unit\":\"y\"}]",
      "[{\"source\":\"a\",\"target\":\"b\",\"scale\":1,\"offset\":0,\"source_unit\":\"x\",\"target_unit\":\"y\",\"extra\":0}]",
      "[{\"source\":\"a\",\"target\":\"b\",\"scale\":1,\"offset\":0,\"source_unit\":\"x\",\"typo\":\"y\"}]",
    ] {
    assert_true(@telemetry_csv.parse_normalization_recipe(bad) is Err(_))
  }
  assert_true(
    @telemetry_csv.normalize_csv("timestamp_ms,a\n0,1", [
      {
        source: "a",
        target: "b",
        scale: 1.0,
        offset: 0.0,
        source_unit: " ",
        target_unit: "m",
      },
    ])
    is Err(_),
  )
}

///|
test "normalized CSV feeds comparison exploration and trajectory without special handling" {
  let raw = "timestamp_ms,raw_x,raw_y,extra\n10000,0,0,9\n10100,300,400,8"
  let result = @telemetry_csv.normalize_csv(raw, [
    mapping("raw_x", "x.m", scale=0.01),
    mapping("raw_y", "y.m", scale=0.01),
  ]).unwrap()
  let csv = result.to_csv().unwrap()
  let comparison = @telemetry_csv.compare_csv(
    "timestamp_ms,x.m,y.m\n0,0,0\n100,3,4", csv,
  ).unwrap()
  assert_eq(comparison.compared_count, 2)
  assert_eq(comparison.summaries[0].max_absolute_delta, 0.0)
  assert_eq(comparison.summaries[1].max_absolute_delta, 0.0)
  assert_eq(@telemetry_csv.explore_csv(csv).unwrap().sample_count, 2)
  assert_eq(
    @telemetry_csv.trajectory_csv(csv, "x.m", "y.m", units="m").unwrap().observed_distance,
    5.0,
  )
  for _ in 0..<5 {
    assert_eq(
      @telemetry_csv.normalize_csv(raw, [
        mapping("raw_x", "x.m", scale=0.01),
        mapping("raw_y", "y.m", scale=0.01),
      ])
      .unwrap()
      .to_csv()
      .unwrap(),
      csv,
    )
  }
}
