///|
let exclusion_fixture : String =
  #|timestamp_ms,x,y
  #|0,0,20
  #|100,1,21
  #|200,999,99
  #|300,999,99
  #|400,4,24
  #|500,5,25
  #|600,6,26
  #|800,8,28
  #|900,9,29
  #|2000,20,30
  #|2100,21,31

///|
fn exclusion_recipe() -> @telemetry_csv.ExclusionRecipe {
  {
    editor_label: "test",
    max_gap_ms: 250L,
    intervals: [
      { id: "a", start_ms: 150L, end_ms: 300L, reason: "connector", },
      { id: "b", start_ms: 250L, end_ms: 350L, reason: "overlap", },
      { id: "c", start_ms: 650L, end_ms: 750L, reason: "between", },
      { id: "d", start_ms: 3000L, end_ms: 3100L, reason: "unmatched", },
    ],
  }
}

///|
test "exclusion preview retains original rows and all overlap reasons" {
  let r = @telemetry_csv.exclude_csv(exclusion_fixture, exclusion_recipe()).unwrap()
  assert_eq(r.source, @telemetry_csv.parse(exclusion_fixture).unwrap())
  assert_eq(r.retained_sample_count, 9)
  assert_eq(r.excluded_sample_count, 2)
  assert_eq(r.rows.length(), 11)
  assert_eq(r.rows[2].interval_ids, ["a"])
  assert_eq(r.rows[3].interval_ids, ["a", "b"])
  assert_eq(r.rows[2].segment, None)
  assert_eq(r.rows[3].segment, None)
  assert_eq(r.coverage.map(c => c.matched_sample_count), [2, 1, 0, 0])
  assert_eq(r.coverage.map(c => c.crossed_boundary_count), [1, 1, 1, 0])
  assert_eq(r.segments.map(s => s.sample_count), [2, 3, 2, 2])
  assert_eq(r.segments.map(s => s.first_source_sample_index), [0, 4, 7, 9])
  assert_eq(r.segments.map(s => s.last_source_sample_index), [1, 6, 8, 10])
  assert_eq(r.boundaries[0].interval_ids, ["a", "b"])
  assert_true(r.boundaries[0].exceeds_max_gap)
  assert_eq(r.boundaries[1].interval_ids, ["c"])
  assert_false(r.boundaries[1].exceeds_max_gap)
  assert_eq(r.boundaries[2].interval_ids, [])
  assert_true(r.boundaries[2].exceeds_max_gap)
}

///|
test "exclusion CSV exports exactly one retained segment usable by existing analysis" {
  let r = @telemetry_csv.exclude_csv(exclusion_fixture, exclusion_recipe()).unwrap()
  assert_true(r.to_csv() is Err(_))
  assert_true(r.to_csv(segment=-1) is Err(_))
  assert_true(r.to_csv(segment=4) is Err(_))
  let csv = r.to_csv(segment=1).unwrap()
  assert_eq(csv, "timestamp_ms,x,y\n400,4,24\n500,5,25\n600,6,26\n")
  let explored = @telemetry_csv.explore_csv(csv).unwrap()
  assert_eq(explored.sample_count, 3)
  assert_eq(explored.summaries[0].maximum, 6.0)
  let motion = @telemetry_csv.motion_csv(
    csv,
    ["x"],
    unit_labels=["units"],
    order=1,
    max_gap_ms=250L,
  ).unwrap()
  assert_true(motion.recording.samples.length() > 0)
  for segment in r.segments {
    let parsed = @telemetry_csv.parse(r.to_csv(segment=segment.index).unwrap()).unwrap()
    assert_eq(parsed.samples.length(), segment.sample_count)
    assert_eq(parsed.samples[0].timestamp_ms, segment.start_ms)
    assert_eq(
      parsed.samples[parsed.samples.length() - 1].timestamp_ms,
      segment.end_ms,
    )
  }
}

///|
test "exclusion closed endpoints singleton prefix suffix all excluded and empty recipe" {
  let base = exclusion_recipe()
  let source = "timestamp_ms,x\n0,1\n10,2\n20,3\n"
  for
    (start, end, expected) in [
      (0L, 0L, 1),
      (10L, 10L, 1),
      (20L, 20L, 1),
      (0L, 20L, 3),
      (30L, 40L, 0),
    ] {
    let r = @telemetry_csv.exclude_csv(source, {
      ..base,
      intervals: [{ id: "edit", start_ms: start, end_ms: end, reason: "test", }],
    }).unwrap()
    assert_eq(r.excluded_sample_count, expected)
    if expected == 3 {
      assert_eq(r.segments.length(), 0)
      assert_eq(r.boundaries.length(), 0)
      assert_true(r.to_csv() is Err(_))
    }
  }
  let r = @telemetry_csv.exclude_csv(source, { ..base, intervals: [], }).unwrap()
  assert_eq(r.to_csv().unwrap(), source)
  assert_eq(r.rows.map(row => row.segment), [Some(0), Some(0), Some(0)])
}

///|
test "exclusion zero-observation intervals still cut retained continuity" {
  let base = exclusion_recipe()
  let source = "timestamp_ms,x\n0,1\n100,2\n200,3\n"
  let r = @telemetry_csv.exclude_csv(source, {
    ..base,
    intervals: [
      {
        id: "cut",
        start_ms: 50L,
        end_ms: 50L,
        reason: "unobserved interruption",
      },
    ],
  }).unwrap()
  assert_eq(r.excluded_sample_count, 0)
  assert_eq(r.segments.length(), 2)
  assert_eq(r.coverage[0].crossed_boundary_count, 1)
  assert_eq(r.coverage[0].matched_sample_count, 0)
  assert_eq(r.to_csv(segment=1).unwrap(), "timestamp_ms,x\n100,2\n200,3\n")
}

///|
test "exclusion gap threshold is inclusive and exact Int64 times never round" {
  let base = exclusion_recipe()
  let source = "timestamp_ms,x\n9223372036854775777,1\n9223372036854775787,2\n9223372036854775798,3\n9223372036854775807,4\n"
  let r = @telemetry_csv.exclude_csv(source, {
    ..base,
    max_gap_ms: 10L,
    intervals: [],
  }).unwrap()
  assert_eq(r.segments.map(s => s.sample_count), [2, 2])
  assert_eq(
    r.to_csv(segment=1).unwrap(),
    "timestamp_ms,x\n9223372036854775798,3\n9223372036854775807,4\n",
  )
  assert_true(r.to_json().stringify().contains("\"9223372036854775807\""))
  let whole = @telemetry_csv.exclude_csv(
    "timestamp_ms,x\n0,1\n9223372036854775807,2\n",
    { ..base, max_gap_ms: 9223372036854775807L, intervals: [], },
  ).unwrap()
  assert_eq(whole.segments.length(), 1)
}

///|
test "exclusion recipe rejects malformed duplicate escaped unknown and numeric times" {
  let valid = exclusion_recipe().to_json().stringify()
  assert_eq(
    @telemetry_csv.parse_exclusion_recipe(valid).unwrap(),
    exclusion_recipe(),
  )
  for
    text in [
      "not-json", "{\"editor_label\":\"e\",\"max_gap_ms\":10,\"intervals\":[]}",
      "{\"editor_label\":\"e\",\"max_gap_ms\":\"10\",\"intervals\":[],\"extra\":0}",
      "{\"editor_label\":\"e\",\"max_gap_ms\":\"10\",\"intervals\":[],\"\\u0069ntervals\":[]}",
      "{\"editor_label\":\"e\",\"max_gap_ms\":\"10\",\"intervals\":[{\"id\":\"a\",\"start_ms\":\"0\",\"end_ms\":\"1\",\"reason\":\"r\",\"reason\":\"other\"}]}",
      "{\"editor_label\":\"e\",\"max_gap_ms\":\"10\",\"intervals\":[{\"id\":\"a\",\"start_ms\":\"0\",\"end_ms\":\"1\",\"extra\":\"r\"}]}",
      "{\"editor_label\":\"e\",\"max_gap_ms\":\"9223372036854775808\",\"intervals\":[]}",
    ] {
    assert_true(@telemetry_csv.parse_exclusion_recipe(text) is Err(_), msg=text)
  }
}

///|
test "exclusion typed API validates bounds labels interval count and duplicate IDs" {
  let base = exclusion_recipe()
  let rule = base.intervals[0]
  for
    recipe in [
      { ..base, editor_label: "  ", },
      { ..base, max_gap_ms: 0L, },
      { ..base, max_gap_ms: -1L, },
      { ..base, intervals: [rule, rule], },
      { ..base, intervals: [{ ..rule, start_ms: -1L, }], },
      { ..base, intervals: [{ ..rule, end_ms: 100L, }], },
      { ..base, intervals: [{ ..rule, id: "", }], },
      { ..base, intervals: [{ ..rule, reason: "\t", }], },
      { ..base, intervals: Array::make(129, rule), },
    ] {
    assert_true(@telemetry_csv.exclude_csv(exclusion_fixture, recipe) is Err(_))
  }
}

///|
test "exclusion validates excluded rows rather than concealing malformed data" {
  let base = exclusion_recipe()
  for
    text in [
      "timestamp_ms,x\n0,1\n200,NaN\n", "timestamp_ms,x\n0,1\n200,broken\n", "timestamp_ms,x\n0,1\n200,2\n200,3\n",
      "timestamp_ms,x\n0,1\n200,2,3\n", "timestamp_ms,x\n0,1\n200,2\n100,3\n",
    ] {
    assert_true(@telemetry_csv.exclude_csv(text, base) is Err(_))
  }
}

///|
test "exclusion exhaustive small interval selections partition every source row exactly once" {
  let source = "timestamp_ms,x\n0,0\n2,2\n4,4\n6,6\n8,8\n"
  let base = exclusion_recipe()
  for start in 0..<10 {
    for end in start..<10 {
      let r = @telemetry_csv.exclude_csv(source, {
        ..base,
        intervals: [
          {
            id: "range",
            start_ms: start.to_int64(),
            end_ms: end.to_int64(),
            reason: "test",
          },
        ],
      }).unwrap()
      let mut count = 0
      for i, row in r.rows {
        assert_eq(row.source_sample_index, i)
        let inside = i * 2 >= start && i * 2 <= end
        assert_eq(row.segment is None, inside)
        if !inside {
          count += 1
        }
      }
      assert_eq(count, r.retained_sample_count)
      assert_eq(count + r.excluded_sample_count, 5)
      for segment in r.segments {
        let parsed = @telemetry_csv.parse(
          r.to_csv(segment=segment.index).unwrap(),
        ).unwrap()
        for sample in parsed.samples {
          assert_true(
            sample.timestamp_ms < start.to_int64() ||
            sample.timestamp_ms > end.to_int64(),
          )
        }
        assert_true(
          segment.end_ms < start.to_int64() || segment.start_ms > end.to_int64(),
        )
      }
    }
  }
}
