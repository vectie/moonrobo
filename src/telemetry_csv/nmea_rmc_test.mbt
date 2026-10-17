///|
fn rmc_recipe(
  channels? : Array[String] = ["latitude", "longitude", "speed", "course"],
  century? : Int = 2000,
) -> @telemetry_csv.NmeaRmcRecipe {
  { year_century: century, channels, row_policy: "eligible-only", }
}

///|
fn rmc_checked(body : String) -> String {
  let mut checksum = 0
  for ch in body {
    checksum = checksum.lxor(ch.to_int())
  }
  let digits = "0123456789ABCDEF"
  "$" +
  body +
  "*" +
  digits[checksum / 16:checksum / 16 + 1].to_owned() +
  digits[checksum % 16:checksum % 16 + 1].to_owned()
}

///|
fn rmc_body(
  time? : String = "000000.125",
  date? : String = "010100",
  status? : String = "A",
  latitude? : String = "4807.038,N",
  longitude? : String = "01131.000,E",
  speed? : String = "22.4",
  course? : String = "84.4",
  suffix? : String = ",,",
) -> String {
  "GPRMC,\{time},\{status},\{latitude},\{longitude},\{speed},\{course},\{date}\{suffix}"
}

///|
test "RMC documented checksum example degrees units and exact UTC" {
  let result = @telemetry_csv.import_nmea_rmc(
    "$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A",
    rmc_recipe(century=1900),
  ).unwrap()
  assert_eq(result.recording.samples[0].timestamp_ms, 764426119000L)
  let values = result.recording.samples[0].values
  assert_true((values[0] - 48.1173).abs() < 1.0e-12)
  assert_true((values[1] - 11.516666666666667).abs() < 1.0e-12)
  assert_eq(values[2:], [22.4, 84.4][:])
  assert_eq(result.sources[0].magnetic_variation_east_deg, Some(-3.1))
  assert_eq(result.sources[0].position_mode, None)
}

///|
test "RMC fractional UTC and hemisphere signs retain exact strings" {
  let result = @telemetry_csv.import_nmea_rmc(
    rmc_checked(rmc_body(latitude="9000,S", longitude="18000,W")),
    rmc_recipe(),
  ).unwrap()
  assert_eq(result.recording.samples[0].timestamp_ms, 946684800125L)
  assert_eq(result.recording.samples[0].values, [-90.0, -180.0, 22.4, 84.4])
  assert_true(result.to_json().stringify().contains("\"946684800125\""))
}

///|
test "RMC explicit century changes dates without a pivot or current clock" {
  let sentence = rmc_checked(rmc_body(date="010170"))
  assert_eq(
    @telemetry_csv.import_nmea_rmc(sentence, rmc_recipe(century=1900)).unwrap().recording.samples[0].timestamp_ms,
    125L,
  )
  assert_eq(
    @telemetry_csv.import_nmea_rmc(sentence, rmc_recipe()).unwrap().recording.samples[0].timestamp_ms,
    3155760000125L,
  )
  assert_true(
    @telemetry_csv.import_nmea_rmc(
      rmc_checked(rmc_body()),
      rmc_recipe(century=1900),
    )
    is Err(_),
  )
}

///|
test "RMC Gregorian leap day and midnight rollover" {
  let text = rmc_checked(rmc_body(time="235959.999", date="280200")) +
    "\n" +
    rmc_checked(rmc_body(time="000000", date="290200")) +
    "\n" +
    rmc_checked(rmc_body(time="000000", date="010300"))
  let samples = @telemetry_csv.import_nmea_rmc(text, rmc_recipe()).unwrap().recording.samples
  assert_eq(samples[1].timestamp_ms - samples[0].timestamp_ms, 1L)
  assert_eq(samples[2].timestamp_ms - samples[1].timestamp_ms, 86400000L)
  for date in ["290201", "310400", "000100", "011300", "01010a", "10100"] {
    assert_true(
      @telemetry_csv.import_nmea_rmc(rmc_checked(rmc_body(date~)), rmc_recipe())
      is Err(_),
    )
  }
}

///|
test "RMC missing and void fixes stay visible and are never zero filled" {
  let text = rmc_checked(
      rmc_body(status="V", latitude=",", longitude=",", speed="", course=""),
    ) +
    "\n" +
    rmc_checked(rmc_body(time="", date="", status=""))
  let result = @telemetry_csv.import_nmea_rmc(text, rmc_recipe()).unwrap()
  assert_eq(result.sources.length(), 2)
  assert_eq(result.excluded_sentence_count, 2)
  assert_true(result.recording.samples.is_empty())
  assert_eq(result.sources[0].latitude_deg, None)
  assert_true(result.sources[0].exclusion_reasons.contains("void-status"))
  assert_true(result.sources[1].exclusion_reasons.contains("missing-status"))
  assert_true(result.sources[1].exclusion_reasons.contains("missing-date"))
  assert_true(result.sources[1].exclusion_reasons.contains("missing-time"))
  assert_true(result.to_csv() is Err(_))
}

///|
test "RMC channel recipe edit includes active row with missing course" {
  let sentence = rmc_checked(rmc_body(course=""))
  let initial = @telemetry_csv.import_nmea_rmc(sentence, rmc_recipe()).unwrap()
  assert_eq(initial.excluded_sentence_count, 1)
  assert_true(
    initial.sources[0].exclusion_reasons.contains(
      "missing-selected-channel:course",
    ),
  )
  let revised = @telemetry_csv.import_nmea_rmc(
    sentence,
    rmc_recipe(channels=["speed", "longitude"]),
  ).unwrap()
  assert_eq(revised.excluded_sentence_count, 0)
  assert_eq(revised.recording.channels, [
    "gnss.speed.knots", "gnss.longitude.deg",
  ])
  assert_eq(revised.raw_source, initial.raw_source)
  assert_eq(
    @telemetry_csv.parse(revised.to_csv().unwrap()).unwrap(),
    revised.recording,
  )
}

///|
test "RMC position modes preserved including invalid and non-GNSS modes" {
  for mode in ["", "N", "E", "M", "P", "S"] {
    let result = @telemetry_csv.import_nmea_rmc(
      rmc_checked(rmc_body(suffix=",,," + mode)),
      rmc_recipe(),
    ).unwrap()
    assert_eq(result.sources[0].position_mode, Some(mode))
    assert_eq(result.excluded_sentence_count, 1)
  }
  for mode in ["A", "D", "F", "R"] {
    let result = @telemetry_csv.import_nmea_rmc(
      rmc_checked(rmc_body(suffix=",,," + mode)),
      rmc_recipe(),
    ).unwrap()
    assert_eq(result.excluded_sentence_count, 0)
  }
  assert_true(
    @telemetry_csv.import_nmea_rmc(
      rmc_checked(rmc_body(suffix=",,,Q")),
      rmc_recipe(),
    )
    is Err(_),
  )
}

///|
test "RMC GP and GN CRLF blank lines and line-number lineage" {
  let first = rmc_checked(rmc_body())
  let second = rmc_checked(
    rmc_body(time="000001").replace(old="GPRMC", new="GNRMC"),
  )
  let text = "\r\n" + first + "\r\n\n" + second
  let result = @telemetry_csv.import_nmea_rmc(text, rmc_recipe()).unwrap()
  assert_eq(result.exported_source_line_numbers, [2, 4])
  assert_eq(result.sources[1].talker, "GN")
  assert_eq(result.raw_source, text)
}

///|
test "RMC late checksum and shape failures reject whole input" {
  let sentence = rmc_checked(rmc_body())
  for
    bad in [
      sentence + "0",
      sentence.replace(old="22.4", new="22.5"),
      sentence.split("*").next().unwrap().to_owned(),
      " " + sentence,
      sentence + " ",
      sentence.replace(old="A", new="é"),
    ] {
    assert_true(
      @telemetry_csv.import_nmea_rmc(sentence + "\n" + bad, rmc_recipe())
      is Err(_),
    )
  }
  for
    body in [
      rmc_body() + ",A,A",
      rmc_body().replace(old="GPRMC", new="GLRMC"),
      rmc_body().replace(old="GPRMC", new="GPGGA"),
      "GPRMC,000000,A",
    ] {
    assert_true(
      @telemetry_csv.import_nmea_rmc(rmc_checked(body), rmc_recipe()) is Err(_),
    )
  }
}

///|
test "RMC numeric validation also covers excluded and unselected fields" {
  for
    body in [
      rmc_body(status="V", speed="NaN"),
      rmc_body(latitude="4860,N"),
      rmc_body(latitude="9000.1,N"),
      rmc_body(longitude="18100,E"),
      rmc_body(longitude="1131,E"),
      rmc_body(latitude="4807.0,"),
      rmc_body(speed="-1"),
      rmc_body(speed="1e2"),
      rmc_body(course="360"),
      rmc_body(suffix=",181,E"),
      rmc_body(suffix=",2,"),
      rmc_body(status="X"),
    ] {
    assert_true(
      @telemetry_csv.import_nmea_rmc(
        rmc_checked(body),
        rmc_recipe(channels=["speed"]),
      )
      is Err(_),
    )
  }
}

///|
test "RMC exact clock rejects leap seconds sub-ms malformed and invalid fields" {
  for
    time in [
      "235960", "240000", "006000", "000000.0000", "000000.", "00000", "00x000",
      "00:00:00",
    ] {
    assert_true(
      @telemetry_csv.import_nmea_rmc(rmc_checked(rmc_body(time~)), rmc_recipe())
      is Err(_),
    )
  }
  for
    (time, expected) in [
      ("000000", 0L),
      ("000000.1", 100L),
      ("000000.12", 120L),
      ("000000.123", 123L),
    ] {
    let result = @telemetry_csv.import_nmea_rmc(
      rmc_checked(rmc_body(time~)),
      rmc_recipe(),
    ).unwrap()
    assert_eq(
      result.recording.samples[0].timestamp_ms - 946684800000L,
      expected,
    )
  }
}

///|
test "RMC exported ordering rejects duplicates and backward time without sorting" {
  let first = rmc_checked(rmc_body(time="000001"))
  for next in [rmc_body(time="000001"), rmc_body(time="000000")] {
    assert_true(
      @telemetry_csv.import_nmea_rmc(
        first + "\n" + rmc_checked(next),
        rmc_recipe(),
      )
      is Err(_),
    )
  }
  let void = rmc_checked(rmc_body(time="000000", status="V"))
  let result = @telemetry_csv.import_nmea_rmc(first + "\n" + void, rmc_recipe()).unwrap()
  assert_eq(result.sources.length(), 2)
  assert_eq(result.recording.samples.length(), 1)
}

///|
test "RMC excluded rows leave temporal gaps in existing plot continuation" {
  let text = rmc_checked(rmc_body(time="000000")) +
    "\n" +
    rmc_checked(rmc_body(time="000001", status="V")) +
    "\n" +
    rmc_checked(rmc_body(time="000002"))
  let report = @telemetry_csv.import_nmea_rmc(text, rmc_recipe()).unwrap()
  let csv = report.to_csv().unwrap()
  assert_eq(@telemetry_csv.explore_csv(csv).unwrap().sample_count, 2)
  let plot = @telemetry_csv.plot_csv(
    csv,
    ["gnss.speed.knots"],
    unit_labels=["knots"],
    max_gap_ms=1000L,
  ).unwrap()
  assert_eq(plot.segment_count, 2)
  assert_true(plot.to_svg().contains("gnss.speed.knots"))
}

///|
test "RMC recipe validation includes direct constructors and strict JSON" {
  let recipe = rmc_recipe()
  assert_eq(
    @telemetry_csv.parse_nmea_rmc_recipe(recipe.to_json().stringify()).unwrap(),
    recipe,
  )
  for
    bad in [
      "{}", "[]", "{", "{\"year_century\":2000,\"year_century\":1900,\"channels\":[\"speed\"],\"row_policy\":\"eligible-only\"}",
      "{\"year_century\":2000.5,\"channels\":[\"speed\"],\"row_policy\":\"eligible-only\"}",
    ] {
    assert_true(@telemetry_csv.parse_nmea_rmc_recipe(bad) is Err(_))
  }
  for
    recipe in [
      rmc_recipe(channels=[]),
      rmc_recipe(channels=["x"]),
      rmc_recipe(channels=["speed", "speed"]),
      rmc_recipe(century=2100),
      { ..recipe, row_policy: "all", },
    ] {
    assert_true(
      @telemetry_csv.import_nmea_rmc(rmc_checked(rmc_body()), recipe) is Err(_),
    )
  }
  assert_true(@telemetry_csv.import_nmea_rmc("\n\r\n", rmc_recipe()) is Err(_))
}

///|
test "RMC century rejects fractional decimal tails rounded away by binary64" {
  for
    token in [
      "2000.00000000000001", "1999.99999999999999", "1900.00000000000001", "1899.99999999999999",
      "2.00000000000000001e3", "1.99999999999999999e3", "200000000000000001e-14",
      "190000000000000001e-14", "2e999999999999999999999999", "2e-999999999999999999999999",
      "-2000", "2000e1", "1900e-1",
    ] {
    let recipe = "{\"year_century\":\{token},\"channels\":[\"speed\"],\"row_policy\":\"eligible-only\"}"
    assert_true(
      @telemetry_csv.parse_nmea_rmc_recipe(recipe) is Err(_),
      msg=token,
    )
  }
}

///|
test "RMC exact century keeps mathematically integral decimal and exponent forms" {
  for
    (token, expected) in [
      ("2000", 2000),
      ("2000.0", 2000),
      ("2e3", 2000),
      ("2E+0003", 2000),
      ("200000e-2", 2000),
      ("0.002e6", 2000),
      ("2000e-0000", 2000),
      ("2000.0000000000000000000000000", 2000),
      ("200000000000000000000000000e-23", 2000),
      ("1900.0", 1900),
      ("1.9e3", 1900),
      ("19E+02", 1900),
      ("0.00019e7", 1900),
      ("190000000000000000000000000e-23", 1900),
    ] {
    let text = "{\"channels\":[\"speed\"],\"row_policy\":\"eligible-only\",\"year_century\": \{token}}"
    assert_eq(
      @telemetry_csv.parse_nmea_rmc_recipe(text).unwrap().year_century,
      expected,
      msg=token,
    )
  }
}

///|
test "RMC exact century scanner respects escaped keys field order and string contents" {
  let good = "{\"row_policy\":\"eligible-only\", \"year_\\u0063entury\"\t:\n2e3,\"channels\":[\"speed\"]}"
  assert_eq(
    @telemetry_csv.parse_nmea_rmc_recipe(good).unwrap().year_century,
    2000,
  )
  let bad = good.replace(old="2e3", new="2000.00000000000001")
  assert_true(@telemetry_csv.parse_nmea_rmc_recipe(bad) is Err(_))
  for
    bad in [
      "{\"channels\":[\"year_century\",\"2000\"],\"row_policy\":\"eligible-only\",\"year_century\":1900.00000000000001}",
      "{\"channels\":[{\"year_century\":2000}],\"row_policy\":\"eligible-only\",\"year_century\":1900.00000000000001}",
      "{\"channels\":[\"speed\"],\"row_policy\":\"year_century\\\":2000\",\"year_century\":1900.00000000000001}",
    ] {
    assert_true(@telemetry_csv.parse_nmea_rmc_recipe(bad) is Err(_))
  }
}
