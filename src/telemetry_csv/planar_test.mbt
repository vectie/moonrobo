///|
fn planar_recipe(
  alignment? : String = "first-sample",
) -> @telemetry_csv.PlanarRecipe {
  {
    baseline_x: "x",
    baseline_y: "y",
    candidate_x: "cx",
    candidate_y: "cy",
    baseline_frame: "map",
    candidate_frame: "map",
    baseline_units: "m",
    candidate_units: "m",
    alignment,
  }
}

///|
test "planar coupled coordinates separation and numeric lineage across outages" {
  let a = "timestamp_ms,y,temp,x\n100,0,20,0\n105,0,21,5\n110,0,22,10\n120,0,23,20\n150,0,24,50\n160,0,25,60"
  let b = "timestamp_ms,cx,cy\n900,3,4\n910,13,4\n950,53,4"
  let r = @telemetry_csv.compare_planar_csv(
    a,
    b,
    planar_recipe(),
    max_gap_ms=10L,
  ).unwrap()
  assert_eq(r.baseline_source, @telemetry_csv.parse(a).unwrap())
  assert_eq(r.candidate_source, @telemetry_csv.parse(b).unwrap())
  assert_eq(
    (r.compared_count, r.interpolated_count, r.unmatched_count),
    (4, 1, 2),
  )
  assert_eq(r.rows.map(s => s.status), [
    "exact", "interpolated", "exact", "candidate-gap-exceeds-limit", "exact", "outside-candidate-range",
  ])
  assert_eq(r.rows.map(s => s.connected), [
    false, true, true, false, false, false,
  ])
  assert_eq(r.rows[1].candidate.unwrap(), @telemetry_csv.PlanarPosition::{
    x: 8.0,
    y: 4.0,
  })
  assert_eq(r.rows[1].candidate_left_timestamp_ms, Some(900L))
  assert_eq(r.rows[1].candidate_right_timestamp_ms, Some(910L))
  assert_eq(r.rows[3].candidate_left_sample_index, Some(1))
  assert_eq(r.rows[3].candidate_right_sample_index, Some(2))
  assert_eq(r.rows[5].candidate_right_sample_index, None)
  assert_eq(r.rows[3].baseline.x, 20.0)
  assert_eq(r.rows[3].candidate, None)
  assert_true(r.rows[3].to_json().stringify().contains("\"candidate\":null"))
  let summary = r.summary.unwrap()
  assert_eq(
    (
      summary.mean_separation,
      summary.root_mean_square_separation,
      summary.max_separation,
    ),
    (5.0, 5.0, 5.0),
  )
  assert_eq(summary.max_separation_aligned_ms, 0L)
  assert_true(r.to_csv().contains("candidate-gap-exceeds-limit,20,0,,,,false"))
  assert_true(r.to_svg().unwrap().contains("source bracket=[900,910]"))
}

///|
test "planar explicit alignment and exact large clocks" {
  let a = "timestamp_ms,x,y\n9007199254740993,0,0\n9007199254740994,1,0"
  let b = "timestamp_ms,cx,cy\n9007199254740994,3,4\n9007199254740995,4,4"
  let relative = @telemetry_csv.compare_planar_csv(
    a,
    b,
    planar_recipe(),
    start_ms=1L,
  ).unwrap()
  assert_eq(relative.baseline_origin_ms, 9007199254740993L)
  assert_eq(relative.rows[0].aligned_ms, 1L)
  assert_eq(relative.rows[0].baseline_timestamp_ms, 9007199254740994L)
  assert_eq(
    relative.rows[0].candidate_left_timestamp_ms,
    Some(9007199254740995L),
  )
  let absolute = @telemetry_csv.compare_planar_csv(
    a,
    b,
    planar_recipe(alignment="absolute-timestamp"),
  ).unwrap()
  assert_eq(absolute.unmatched_count, 1)
  assert_eq(absolute.rows[0].candidate_left_timestamp_ms, None)
  assert_eq(absolute.rows[1].aligned_ms, 9007199254740994L)
  assert_eq(
    absolute.rows[1].candidate_left_timestamp_ms,
    Some(9007199254740994L),
  )
  let end = @telemetry_csv.compare_planar_csv(
    "timestamp_ms,x,y\n9223372036854775807,0,0",
    "timestamp_ms,cx,cy\n9223372036854775807,3,4",
    planar_recipe(alignment="absolute-timestamp"),
  ).unwrap()
  assert_true(end.to_csv().contains("9223372036854775807,9223372036854775807"))
}

///|
test "planar strict declaration parser and no compatibility inference" {
  let recipe = planar_recipe()
  let valid = recipe.to_json().stringify()
  assert_eq(@telemetry_csv.parse_planar_recipe(valid), Ok(recipe))
  for
    text in [
      "{}",
      "[]",
      "bad",
      valid[:valid.length() - 1].to_string() + ",\"extra\":1}",
      valid[:valid.length() - 1].to_string() +
      ",\"alignment\":\"first-sample\"}",
    ] {
    assert_true(@telemetry_csv.parse_planar_recipe(text) is Err(_))
  }
  for
    bad in [
      { ..recipe, candidate_frame: "odom", },
      { ..recipe, candidate_units: "cm", },
      { ..recipe, baseline_frame: "", candidate_frame: "", },
      { ..recipe, baseline_units: " ", candidate_units: " ", },
      { ..recipe, baseline_y: "x", },
      { ..recipe, candidate_y: "cx", },
      { ..recipe, alignment: "auto", },
    ] {
    assert_true(
      @telemetry_csv.compare_planar_csv(
        "timestamp_ms,x,y\n0,0,0", "timestamp_ms,cx,cy\n0,0,0", bad,
      )
      is Err(_),
    )
  }
}

///|
test "planar no pairs stays unknown and exact-only does not draw routes" {
  let a = "timestamp_ms,x,y\n0,0,0\n1,1,1"
  let b = "timestamp_ms,cx,cy\n5,0,0\n6,1,1"
  let r = @telemetry_csv.compare_planar_csv(
    a,
    b,
    planar_recipe(alignment="absolute-timestamp"),
  ).unwrap()
  assert_eq((r.compared_count, r.unmatched_count), (0, 2))
  assert_eq(r.summary, None)
  assert_true(r.to_json().stringify().contains("\"summary\":null"))
  assert_true(!r.to_svg().unwrap().contains("<line"))
  assert_true(
    @telemetry_csv.compare_planar_csv(a, b, planar_recipe(), start_ms=10L)
    is Err(_),
  )
  let exact = @telemetry_csv.compare_planar_csv(a, b, planar_recipe()).unwrap()
  assert_eq(exact.rows.map(r => r.connected), [false, false])
}

///|
test "planar source outages disconnect exact endpoints without interior rows" {
  let a = "timestamp_ms,x,y\n0,0,0\n10,10,0"
  let b = "timestamp_ms,cx,cy\n0,0,0\n10,10,0"
  let r = @telemetry_csv.compare_planar_csv(
    a,
    b,
    planar_recipe(),
    max_gap_ms=5L,
  ).unwrap()
  assert_eq(r.compared_count, 2)
  assert_eq(r.rows[1].connected, false)
  assert_true(!r.to_svg().unwrap().contains("<line"))
  let escaped = @telemetry_csv.compare_planar_csv(a, b, {
      ..planar_recipe(),
      baseline_frame: "map<&",
      candidate_frame: "map<&",
    })
    .unwrap()
    .to_svg()
    .unwrap()
  assert_true(escaped.contains("map&lt;&amp;"))
}

///|
test "planar scaled Euclidean arithmetic rejects nonfinite results" {
  let r = @telemetry_csv.compare_planar_csv(
    "timestamp_ms,x,y\n0,0,0",
    "timestamp_ms,cx,cy\n0,3.0e200,4.0e200",
    planar_recipe(),
  ).unwrap()
  assert_true(
    (r.summary.unwrap().max_separation / 5.0e200 - 1.0).abs() < 1.0e-14,
  )
  assert_true(
    @telemetry_csv.compare_planar_csv(
      "timestamp_ms,x,y\n0,-1.0e308,0",
      "timestamp_ms,cx,cy\n0,1.0e308,0",
      planar_recipe(),
    )
    is Err(_),
  )
  assert_true(
    @telemetry_csv.compare_planar_csv(
      "timestamp_ms,x,y\n0,0,0",
      "timestamp_ms,cx,cy\n0,1.7e308,1.7e308",
      planar_recipe(),
    )
    is Err(_),
  )
  let extent = @telemetry_csv.compare_planar_csv(
    "timestamp_ms,x,y\n0,-1.0e308,0\n1,1.0e308,0",
    "timestamp_ms,cx,cy\n0,-1.0e308,0\n1,1.0e308,0",
    planar_recipe(),
  ).unwrap()
  assert_true(extent.to_svg() is Err(_))
}

///|
test "planar validates all source rows columns and limits before selecting" {
  let b = "timestamp_ms,cx,cy\n0,0,0"
  for
    a in [
      "timestamp_ms,x,y,temp\n0,0,0,1\n10,1,1,NaN", "timestamp_ms,x,y\n0,0,0\n0,1,1",
      "timestamp_ms,x,z\n0,0,0",
    ] {
    assert_true(
      @telemetry_csv.compare_planar_csv(a, b, planar_recipe(), end_ms=0L)
      is Err(_),
    )
  }
  let a = "timestamp_ms,x,y\n0,0,0"
  assert_true(
    @telemetry_csv.compare_planar_csv(a, b, planar_recipe(), max_gap_ms=-1L)
    is Err(_),
  )
  assert_true(
    @telemetry_csv.compare_planar_csv(
      a,
      b,
      planar_recipe(),
      start_ms=2L,
      end_ms=1L,
    )
    is Err(_),
  )
}

///|
test "planar quoted labels preserve CSV fields and repeated XML metacharacters" {
  let frame = "dock \"A\", floor<&<&"
  let units = "m \"u\", <&<&"
  let recipe = {
    ..planar_recipe(),
    baseline_frame: frame,
    candidate_frame: frame,
    baseline_units: units,
    candidate_units: units,
  }
  let result = @telemetry_csv.compare_planar_csv(
    "timestamp_ms,x,y\n0,0,0", "timestamp_ms,cx,cy\n0,3,4", recipe,
  ).unwrap()
  assert_true(result.to_csv().contains("\"dock \"\"A\"\", floor<&<&\""))
  assert_true(result.to_csv().contains("\"m \"\"u\"\", <&<&\""))
  let svg = result.to_svg().unwrap()
  assert_true(svg.contains("dock &quot;A&quot;, floor&lt;&amp;&lt;&amp;"))
  assert_true(svg.contains("m &quot;u&quot;, &lt;&amp;&lt;&amp;"))
}
