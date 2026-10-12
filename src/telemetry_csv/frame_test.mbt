///|
fn frame_recipe(
  yaw? : Double = 90.0,
  tx? : Double = 10.0,
  ty? : Double = -2.0,
  source_x? : String = "x",
  source_y? : String = "y",
  target_x? : String = "map.x",
  target_y? : String = "map.y",
  source_frame? : String = "odom",
  target_frame? : String = "map",
  units? : String = "m",
) -> @telemetry_csv.FrameRecipe {
  {
    source_x,
    source_y,
    target_x,
    target_y,
    source_frame,
    target_frame,
    units,
    yaw_degrees: yaw,
    translation_x: tx,
    translation_y: ty,
  }
}

///|
test "frame transform keeps source columns exact timestamps and ordered row lineage" {
  let csv = "timestamp_ms,y,temp,x\n9007199254740993,4,12,3\n9223372036854775807,7,15,-2"
  let result = @telemetry_csv.transform_frame_csv(csv, frame_recipe()).unwrap()
  assert_eq(result.source, @telemetry_csv.parse(csv).unwrap())
  assert_eq(result.recording.channels, ["y", "temp", "x", "map.x", "map.y"])
  assert_eq(result.recording.samples[0].values, [4.0, 12.0, 3.0, 6.0, 1.0])
  assert_eq(result.recording.samples[1].values, [7.0, 15.0, -2.0, 3.0, -4.0])
  assert_eq(result.recording.samples[0].timestamp_ms, 9007199254740993L)
  assert_eq(result.recording.samples[1].timestamp_ms, 9223372036854775807L)
  assert_eq(
    @telemetry_csv.parse(result.to_csv().unwrap()).unwrap(),
    result.recording,
  )
  assert_eq(result.recipe, frame_recipe())
}

///|
test "frame cardinal directions translation order and identity rotation" {
  let text = "timestamp_ms,x,y\n0,3,4"
  for
    (yaw, x, y) in [
      (0.0, 13.0, 2.0),
      (90.0, 6.0, 1.0),
      (-90.0, 14.0, -5.0),
      (180.0, 7.0, -6.0),
      (-180.0, 7.0, -6.0),
    ] {
    let result = @telemetry_csv.transform_frame_csv(text, frame_recipe(yaw~)).unwrap()
    assert_eq(result.recording.samples[0].values, [3.0, 4.0, x, y])
  }
  let large = @telemetry_csv.transform_frame_csv(
    "timestamp_ms,x,y\n0,1.0e308,0",
    frame_recipe(tx=0.0, ty=0.0),
  ).unwrap()
  assert_eq(large.recording.samples[0].values, [1.0e308, 0.0, 0.0, 1.0e308])
}

///|
test "frame arbitrary rotation can be inverted with target-frame translation" {
  let text = "timestamp_ms,x,y\n0,3,4\n2,-5,7"
  let forward = @telemetry_csv.transform_frame_csv(text, frame_recipe(yaw=30.0)).unwrap()
  // Inverse translation is -R(-30 degrees) * (10, -2), not merely (-10, 2).
  let c = 0.8660254037844386
  let inverse = @telemetry_csv.transform_frame_csv(
    forward.to_csv().unwrap(),
    frame_recipe(
      yaw=-30.0,
      tx=1.0 - 10.0 * c,
      ty=5.0 + 2.0 * c,
      source_x="map.x",
      source_y="map.y",
      target_x="restored.x",
      target_y="restored.y",
      source_frame="map",
      target_frame="odom",
    ),
  ).unwrap()
  assert_true(
    (forward.recording.samples[0].values[2] - (3.0 * c + 8.0)).abs() < 1.0e-12,
  )
  for i, sample in inverse.recording.samples {
    assert_true(
      (sample.values[4] - forward.source.samples[i].values[0]).abs() < 1.0e-12,
    )
    assert_true(
      (sample.values[5] - forward.source.samples[i].values[1]).abs() < 1.0e-12,
    )
  }
}

///|
test "frame transformed route retains outages and observed distance" {
  let text = "timestamp_ms,x,y\n0,0,0\n1000,3,4\n5000,100,100\n6000,100,103"
  let result = @telemetry_csv.transform_frame_csv(text, frame_recipe()).unwrap()
  let path = @telemetry_csv.trajectory_csv(
    result.to_csv().unwrap(),
    "map.x",
    "map.y",
    units="m",
  ).unwrap()
  assert_eq(path.segment_count, 2)
  assert_eq(path.gap_count, 1)
  assert_eq(path.observed_duration_ms, 2000L)
  assert_eq(path.observed_distance, 8.0)
  assert_eq(path.peak_interval_speed, 5.0)
  assert_eq(result.recording.samples.length(), 4)
}

///|
test "frame recipe parsing requires explicit unambiguous complete fields" {
  let valid = frame_recipe().to_json().stringify()
  assert_eq(@telemetry_csv.parse_frame_recipe(valid), Ok(frame_recipe()))
  for
    text in ["[]", "{}", "bad JSON", "{\"source_x\":\"x\",\"source_x\":\"y\"}"] {
    assert_true(@telemetry_csv.parse_frame_recipe(text) is Err(_))
  }
  let extended = valid[:valid.length() - 1].to_string() + ",\"unexpected\":1}"
  assert_true(@telemetry_csv.parse_frame_recipe(extended) is Err(_))
}

///|
test "frame rejects ambiguous axes replacements missing columns and bad labels" {
  let text = "timestamp_ms,x,y,temp\n0,1,2,3"
  for
    recipe in [
      frame_recipe(source_y="x"),
      frame_recipe(target_y="map.x"),
      frame_recipe(target_x="temp"),
      frame_recipe(source_x="missing"),
      frame_recipe(target_x="timestamp_ms"),
      frame_recipe(target_x="bad,name"),
      frame_recipe(target_y=" bad"),
      frame_recipe(source_frame=" "),
      frame_recipe(target_frame="odom"),
      frame_recipe(units=""),
    ] {
    assert_true(@telemetry_csv.transform_frame_csv(text, recipe) is Err(_))
  }
}

///|
test "frame validates entire recording and rejects arithmetic outside finite range" {
  for
    text in [
      "timestamp_ms,x,y,temp\n0,1,2,NaN", "timestamp_ms,x,y\n0,1,2\n0,2,3", "timestamp_ms,x,y\n0,1,2\n1,bad,3",
      "timestamp_ms,x,y\n",
    ] {
    assert_true(
      @telemetry_csv.transform_frame_csv(text, frame_recipe()) is Err(_),
    )
  }
  let text = "timestamp_ms,x,y\n0,1,2"
  for
    recipe in [
      frame_recipe(yaw=181.0),
      frame_recipe(yaw=-181.0),
      frame_recipe(yaw=0.0 / 0.0),
      frame_recipe(tx=1.0 / 0.0),
      frame_recipe(ty=0.0 / 0.0),
    ] {
    assert_true(@telemetry_csv.transform_frame_csv(text, recipe) is Err(_))
  }
  assert_true(
    @telemetry_csv.transform_frame_csv(
      "timestamp_ms,x,y\n0,1.0e308,0",
      frame_recipe(yaw=0.0, tx=1.0e308),
    )
    is Err(_),
  )
}
