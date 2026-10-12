///|
test "buckets literal uneven observations boundaries selection order and source membership" {
  let text = "timestamp_ms,a,b\n0,99,990\n1,1,10\n9,9,90\n10,3,30\n11,7,70\n40,-2,-20\n41,6,60\n70,100,1000\n"
  guard @telemetry_csv.bucket_csv(
      text,
      ["b", "a"],
      width_ms=10L,
      alignment="zero",
      start_ms=1L,
      end_ms=69L,
    )
    is Ok(r) else {
    fail("bucket failed")
  }
  assert_eq(r.channels, ["b", "a"])
  assert_eq(r.source_sample_count, 8)
  assert_eq(r.selected_sample_count, 6)
  assert_eq(r.total_bucket_count, 7UL)
  assert_eq(r.buckets.map(b => b.index), [0L, 1L, 4L])
  assert_eq(r.buckets.map(b => b.sample_count), [2, 2, 2])
  assert_eq(r.buckets.map(b => b.source_sample_indices), [
    [1, 2],
    [3, 4],
    [5, 6],
  ])
  assert_eq(r.buckets.map(b => b.source_timestamps_ms), [
    [1L, 9L],
    [10L, 11L],
    [40L, 41L],
  ])
  let first = r.buckets[0]
  assert_eq(
    (
      first.start_ms,
      first.end_ms,
      first.selected_start_ms,
      first.selected_end_ms,
    ),
    (0L, 9L, 1L, 9L),
  )
  assert_eq(first.statistics.map(s => s.channel), ["b", "a"])
  assert_eq(first.statistics[1].first, 1.0)
  assert_eq(first.statistics[1].last, 9.0)
  assert_eq(first.statistics[1].minimum, 1.0)
  assert_eq(first.statistics[1].maximum, 9.0)
  assert_eq(first.statistics[1].sample_weighted_mean, 5.0)
  assert_eq(r.buckets[2].statistics[1].sample_weighted_mean, 2.0)
  assert_eq(
    r.gaps.map(g => (g.first_index, g.last_index, g.empty_bucket_count)),
    [(2L, 3L, 2UL), (5L, 6L, 2UL)],
  )
  assert_eq(r.gaps.map(g => (g.selected_start_ms, g.selected_end_ms)), [
    (20L, 39L),
    (50L, 69L),
  ])
}

///|
test "window alignment changes membership and preserves inclusive end sample" {
  let text = "timestamp_ms,v\n0,100\n5,1\n9,3\n10,5\n14,7\n15,9\n16,100\n"
  guard @telemetry_csv.bucket_csv(
      text,
      ["v"],
      width_ms=10L,
      alignment="zero",
      start_ms=5L,
      end_ms=15L,
    )
    is Ok(z) else {
    fail("zero failed")
  }
  guard @telemetry_csv.bucket_csv(
      text,
      ["v"],
      width_ms=10L,
      alignment="window",
      start_ms=5L,
      end_ms=15L,
    )
    is Ok(w) else {
    fail("window failed")
  }
  assert_eq(z.origin_ms, 0L)
  assert_eq(w.origin_ms, 5L)
  assert_eq(z.buckets.map(b => b.source_sample_indices), [[1, 2], [3, 4, 5]])
  assert_eq(w.buckets.map(b => b.source_sample_indices), [[1, 2, 3, 4], [5]])
  assert_eq(w.buckets.map(b => b.statistics[0].sample_weighted_mean), [4.0, 9.0])
  assert_eq(w.buckets[1].selected_end_ms, 15L)
  assert_eq(w.buckets[1].end_ms, 24L)
  assert_eq(w.selected_sample_count, 5)
}

///|
test "first last ties and sample mean do not time weight or infer duration" {
  guard @telemetry_csv.bucket_csv(
      "timestamp_ms,v\n0,4\n1,10\n99,4\n",
      ["v"],
      width_ms=100L,
      alignment="zero",
      start_ms=0L,
      end_ms=99L,
    )
    is Ok(r) else {
    fail("failed")
  }
  let s = r.buckets[0].statistics[0]
  assert_eq((s.first, s.last, s.minimum, s.maximum), (4.0, 4.0, 4.0, 10.0))
  assert_true((s.sample_weighted_mean - 6.0).abs() < 1.0e-14)
  assert_eq(
    r.weighting,
    "equal-weight-per-selected-source-sample-no-time-weighting",
  )
  assert_eq(r.gaps.length(), 0)
}

///|
test "empty selected window leading and trailing sparse spans have no values" {
  let text = "timestamp_ms,v\n40,3\n"
  guard @telemetry_csv.bucket_csv(
      text,
      ["v"],
      width_ms=10L,
      alignment="zero",
      start_ms=22L,
      end_ms=38L,
    )
    is Ok(empty) else {
    fail("empty failed")
  }
  assert_eq(empty.selected_sample_count, 0)
  assert_eq(empty.buckets.length(), 0)
  assert_eq(empty.gaps.length(), 1)
  assert_eq(
    (
      empty.gaps[0].first_index,
      empty.gaps[0].last_index,
      empty.gaps[0].empty_bucket_count,
    ),
    (2L, 3L, 2UL),
  )
  assert_eq(
    (empty.gaps[0].selected_start_ms, empty.gaps[0].selected_end_ms),
    (22L, 38L),
  )
  guard @telemetry_csv.bucket_csv(
      text,
      ["v"],
      width_ms=10L,
      alignment="zero",
      start_ms=22L,
      end_ms=68L,
    )
    is Ok(r) else {
    fail("gaps failed")
  }
  assert_eq(r.gaps.map(g => (g.first_index, g.last_index)), [(2L, 3L), (5L, 6L)])
  assert_eq(r.buckets[0].sample_count, 1)
  assert_eq(r.buckets[0].statistics[0].sample_weighted_mean, 3.0)
  assert_eq(
    empty.to_csv().split("\n").collect()[1],
    "empty-span,zero,0,10,22,38,1,2,3,22,38,2,,0,,,,,,,,,",
  )
}

///|
test "full Int64 window width one compresses billions of empty buckets exactly" {
  guard @telemetry_csv.bucket_csv(
      "timestamp_ms,v\n0,1\n9223372036854775807,2\n",
      ["v"],
      width_ms=1L,
      alignment="zero",
      start_ms=0L,
      end_ms=9223372036854775807L,
    )
    is Ok(r) else {
    fail("failed")
  }
  assert_eq(r.total_bucket_count, 9223372036854775808UL)
  assert_eq(r.buckets.map(b => b.index), [0L, 9223372036854775807L])
  assert_eq(r.buckets[1].end_ms, 9223372036854775807L)
  assert_eq(r.gaps.length(), 1)
  assert_eq(r.gaps[0].empty_bucket_count, 9223372036854775806UL)
  assert_eq(
    (r.gaps[0].selected_start_ms, r.gaps[0].selected_end_ms),
    (1L, 9223372036854775806L),
  )
  assert_true(r.to_csv().length() < 2000)
  let json = r.to_json().stringify()
  assert_true(json.contains("\"9223372036854775808\""))
  assert_true(json.contains("\"9223372036854775807\""))
}

///|
test "large exact timestamps and capped final bucket avoid overflow on native and JS" {
  let text = "timestamp_ms,v\n9007199254740993,1\n9007199254740994,2\n9007199254741003,3\n"
  guard @telemetry_csv.bucket_csv(
      text,
      ["v"],
      width_ms=10L,
      alignment="window",
      start_ms=9007199254740993L,
      end_ms=9007199254741003L,
    )
    is Ok(r) else {
    fail("large failed")
  }
  assert_eq(r.buckets.map(b => b.source_timestamps_ms), [
    [9007199254740993L, 9007199254740994L],
    [9007199254741003L],
  ])
  assert_eq(r.buckets.map(b => b.start_ms), [
    9007199254740993L, 9007199254741003L,
  ])
  guard @telemetry_csv.bucket_csv(
      "timestamp_ms,v\n9223372036854775806,1\n9223372036854775807,2\n",
      ["v"],
      width_ms=9223372036854775807L,
      alignment="zero",
      start_ms=0L,
      end_ms=9223372036854775807L,
    )
    is Ok(edge) else {
    fail("edge failed")
  }
  assert_eq(edge.buckets.map(b => (b.start_ms, b.end_ms)), [
    (0L, 9223372036854775806L),
    (9223372036854775807L, 9223372036854775807L),
  ])
  guard @telemetry_csv.bucket_csv(
      "timestamp_ms,v\n9223372036854775807,2\n",
      ["v"],
      width_ms=9223372036854775807L,
      alignment="window",
      start_ms=9223372036854775807L,
      end_ms=9223372036854775807L,
    )
    is Ok(single) else {
    fail("single failed")
  }
  assert_eq(single.buckets[0].end_ms, 9223372036854775807L)
  assert_eq(single.total_bucket_count, 1UL)
}

///|
test "finite extremes constant tiny negative and zero means remain finite" {
  for
    (values, expected) in [
      (
        "1.7976931348623157e308\n1,1.7976931348623157e308", 1.7976931348623157e308,
      ),
      ("-1.7976931348623157e308\n1,1.7976931348623157e308", 0.0),
      (
        "-1.7976931348623157e308\n1,-1.7976931348623157e308", -1.7976931348623157e308,
      ),
      ("5e-324\n1,5e-324", 5.0e-324),
      ("-6\n1,-2", -4.0),
      ("0\n1,0", 0.0),
    ] {
    guard @telemetry_csv.bucket_csv(
        "timestamp_ms,v\n0," + values + "\n",
        ["v"],
        width_ms=2L,
        alignment="zero",
        start_ms=0L,
        end_ms=1L,
      )
      is Ok(r) else {
      fail("failed")
    }
    let mean = r.buckets[0].statistics[0].sample_weighted_mean
    assert_eq(mean, expected)
    assert_false(mean.is_inf())
    assert_false(mean.is_nan())
    assert_false(r.to_csv().contains("Infinity"))
  }
}

///|
test "buckets refuse invalid choices and validate all rows before selection" {
  let text = "timestamp_ms,v\n0,1\n"
  for
    (width, start, end, align, channels) in [
      (0L, 0L, 1L, "zero", ["v"]),
      (-1L, 0L, 1L, "zero", ["v"]),
      (1L, -1L, 1L, "zero", ["v"]),
      (1L, 2L, 1L, "zero", ["v"]),
      (1L, 0L, 1L, "first", ["v"]),
      (1L, 0L, 1L, "zero", []),
      (1L, 0L, 1L, "zero", ["missing"]),
      (1L, 0L, 1L, "zero", ["v", "v"]),
    ] {
    assert_true(
      @telemetry_csv.bucket_csv(
        text,
        channels,
        width_ms=width,
        alignment=align,
        start_ms=start,
        end_ms=end,
      )
      is Err(_),
    )
  }
  for
    bad in [
      "timestamp_ms,v,other\n0,1,0\n10,1,NaN\n", "timestamp_ms,v\n0,1\n10,Infinity\n",
      "timestamp_ms,v\n0,1\n10,1\n9,2\n", "timestamp_ms,v\n0,1\n0,2\n", "timestamp_ms,v\n0,1\n10\n",
      "timestamp_ms,v,v\n0,1,2\n", "timestamp_ms,v\n", "timestamp_ms,v\n-1,1\n",
      "timestamp_ms,v\n9223372036854775808,1\n", "timestamp_ms,v\n0,1\n10,\"2\"\n",
    ] {
    assert_true(
      @telemetry_csv.bucket_csv(
        bad,
        ["v"],
        width_ms=1L,
        alignment="zero",
        start_ms=0L,
        end_ms=0L,
      )
      is Err(_),
    )
  }
}

///|
test "CSV exports chronological rows complete membership and stable channel order" {
  guard @telemetry_csv.bucket_csv(
      "timestamp_ms,温度;A,b\n10,1,2\n11,3,4\n",
      ["b", "温度;A"],
      width_ms=10L,
      alignment="zero",
      start_ms=0L,
      end_ms=29L,
    )
    is Ok(r) else {
    fail("failed")
  }
  let lines = r.to_csv().split("\n").collect()
  assert_eq(lines.length(), 6)
  for i in 0..<5 {
    assert_eq(lines[i].split(",").count(), 23)
  }
  assert_eq(lines[1], "empty-span,zero,0,10,0,29,2,0,0,0,9,1,,0,,,,,,,,,")
  assert_eq(
    lines[2],
    "observed,zero,0,10,0,29,2,1,1,10,19,0,\"b\",2,10,11,2,4,2,4,3,0;1,10;11",
  )
  assert_eq(
    lines[3],
    "observed,zero,0,10,0,29,2,1,1,10,19,0,\"温度;A\",2,10,11,1,3,1,3,2,0;1,10;11",
  )
  assert_eq(lines[4], "empty-span,zero,0,10,0,29,2,2,2,20,29,1,,0,,,,,,,,,")
  assert_eq(r.to_csv(), r.to_csv())
}

///|
test "blank CRLF source positions and caller channel array are independent" {
  let channels = ["v"]
  guard @telemetry_csv.bucket_csv(
      "\r\ntimestamp_ms,v\r\n\r\n10,1\r\n\r\n20,3",
      channels,
      width_ms=10L,
      alignment="window",
      start_ms=20L,
      end_ms=20L,
    )
    is Ok(r) else {
    fail("failed")
  }
  channels[0] = "changed"
  assert_eq(r.channels, ["v"])
  assert_eq(r.buckets[0].source_sample_indices, [1])
  assert_eq(r.buckets[0].statistics[0].channel, "v")
  assert_eq(r.source_sample_count, 2)
}

///|
test "JSONL import to CSV to bucket retains exact positions for source line join" {
  let source = "{\"t\":\"9007199254740993\",\"v\":1}\n\n{\"t\":\"9007199254740994\",\"v\":3}\n{\"t\":\"9007199254741013\",\"v\":7}\n"
  guard @telemetry_csv.parse_jsonl_recipe(
      "{\"timestamp_path\":[\"t\"],\"channels\":[{\"path\":[\"v\"],\"target\":\"value\",\"unit\":\"A\"}]}",
    )
    is Ok(recipe) else {
    fail("recipe failed")
  }
  guard @telemetry_csv.import_jsonl(source, recipe) is Ok(imported) else {
    fail("import failed")
  }
  guard imported.to_csv() is Ok(csv) else { fail("csv failed") }
  guard @telemetry_csv.bucket_csv(
      csv,
      ["value"],
      width_ms=10L,
      alignment="window",
      start_ms=9007199254740993L,
      end_ms=9007199254741013L,
    )
    is Ok(r) else {
    fail("buckets failed")
  }
  assert_eq(imported.source_line_numbers, [1, 3, 4])
  assert_eq(
    r.buckets[0].source_sample_indices.map(i => imported.source_line_numbers[i]),
    [1, 3],
  )
  assert_eq(r.buckets[0].statistics[0].sample_weighted_mean, 2.0)
  assert_eq(r.gaps[0].first_index, 1L)
  assert_eq(r.buckets[1].source_timestamps_ms, [9007199254741013L])
}
