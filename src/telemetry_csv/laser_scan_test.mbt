///|
fn scan_fixture(
  ranges : String,
  min? : Double = -1.5707963267948966,
  max? : Double = 1.5707963267948966,
  step? : Double = 1.5707963267948966,
) -> String {
  (
    $|{"header":{"stamp":{"sec":10,"nanosec":123456789},"frame_id":"laser"},"angle_min":\{min},"angle_max":\{max},"angle_increment":\{step},"time_increment":0.0001,"scan_time":0.1,"range_min":0.1,"range_max":10,"ranges":\{ranges},"intensities":[]}
  )
}

///|
test "LaserScan projects cardinal returns and preserves exact stamps and source lines" {
  let r = @telemetry_csv.import_laser_scan_jsonl(
    "\n" + scan_fixture("[2,3,4]") + "\n",
    "laser",
  ).unwrap()
  let s = r.scans[0]
  assert_eq(s.source_line_number, 2)
  assert_eq(s.sec, 10)
  assert_eq(s.nanosec, 123456789)
  assert_eq(s.usable_count, 3)
  assert_true(s.beams[0].to_json().stringify().contains("\"range_m\":2"))
  assert_true(s.beams[0].x_m.unwrap().abs() < 1.0e-14)
  assert_eq(s.beams[0].y_m, Some(-2.0))
  assert_eq(s.beams[1].x_m, Some(3.0))
  assert_eq(s.beams[1].y_m, Some(0.0))
  assert_eq(s.beams[2].y_m, Some(4.0))
  assert_eq(s.beams[2].acquisition_offset_s, 0.0002)
  assert_eq(s.beams[2].index, 2)
}

///|
test "LaserScan retains invalid ranges and includes both inclusive bounds" {
  let s = @telemetry_csv.import_laser_scan_jsonl(
      scan_fixture(
        "[0.1,10,0.09,10.01,null,\"NaN\",\"Infinity\",\"+Infinity\",\"-Infinity\"]",
        min=0,
        max=0.8,
        step=0.1,
      ),
      "laser",
    ).unwrap().scans[0]
  assert_eq(s.usable_count, 2)
  assert_eq(s.beams.map(b => b.status), [
    "usable", "usable", "below-range", "above-range", "missing", "nan", "positive-infinity",
    "positive-infinity", "negative-infinity",
  ])
  for i in 2..<9 {
    assert_eq(s.beams[i].x_m, None)
    assert_eq(s.beams[i].y_m, None)
  }
  assert_eq(s.beams[2].range_m, Some(0.09))
  assert_eq(s.beams[5].raw_range, "NaN".to_json())
  assert_true(s.to_csv().contains("\"\"\"NaN\"\"\",nan"))
  assert_eq(s.to_csv().split("\n").count(), 11)
}

///|
test "LaserScan supports negative increment and ordered device intensity" {
  let text = scan_fixture(
    "[2,3,4]",
    min=1.5707963267948966,
    max=-1.5707963267948966,
    step=-1.5707963267948966,
  ).replace(old="\"intensities\":[]", new="\"intensities\":[20,null,40]")
  let s = @telemetry_csv.import_laser_scan_jsonl(text, "laser").unwrap().scans[0]
  assert_eq(s.beams[0].y_m, Some(2.0))
  assert_eq(s.beams[2].y_m, Some(-4.0))
  assert_eq(s.beams.map(b => b.intensity), [Some(20.0), None, Some(40.0)])
}

///|
test "LaserScan all unusable remains an empty scatter without invented points" {
  let s = @telemetry_csv.import_laser_scan_jsonl(
      scan_fixture("[null,\"Infinity\",0]"),
      "laser",
    ).unwrap().scans[0]
  assert_eq(s.usable_count, 0)
  assert_true(s.beams[0].to_json().stringify().contains("\"x_m\":null"))
  assert_true(s.beams[0].to_json().stringify().contains("\"intensity\":null"))
  assert_true(s.to_svg().contains("No usable returns"))
  assert_true(!s.to_svg().contains("<circle"))
  assert_true(s.to_csv().contains("missing,,,"))
}

///|
test "LaserScan rejects inconsistent geometry and malformed intensity" {
  for
    text in [
      scan_fixture("[1,2]"),
      scan_fixture("[1,2,3]", step=0),
      scan_fixture("[]"),
      scan_fixture("[1,2,3]").replace(
        old="\"range_min\":0.1",
        new="\"range_min\":10",
      ),
      scan_fixture("[1,2,3]").replace(
        old="\"time_increment\":0.0001",
        new="\"time_increment\":-1",
      ),
      scan_fixture("[1,2,3]").replace(
        old="\"scan_time\":0.1",
        new="\"scan_time\":-1",
      ),
      scan_fixture("[1,2,3]").replace(
        old="\"intensities\":[]",
        new="\"intensities\":[1]",
      ),
      scan_fixture("[1,2,3]").replace(
        old="\"intensities\":[]",
        new="\"intensities\":[1,\"Infinity\",3]",
      ),
    ] {
    assert_true(@telemetry_csv.import_laser_scan_jsonl(text, "laser") is Err(_))
  }
}

///|
test "LaserScan stamps are exact and monotonic below a millisecond" {
  let a = scan_fixture("[1,2,3]")
  let b = a.replace(old="123456789", new="123456790")
  let r = @telemetry_csv.import_laser_scan_jsonl(a + "\n" + b, "laser").unwrap()
  assert_eq(r.scans[1].nanosec - r.scans[0].nanosec, 1)
  assert_true(
    @telemetry_csv.import_laser_scan_jsonl(a + "\n" + a, "laser") is Err(_),
  )
  assert_true(
    @telemetry_csv.import_laser_scan_jsonl(b + "\n" + a, "laser") is Err(_),
  )
  for stamp in ["-1", "1000000000", "1.5"] {
    assert_true(
      @telemetry_csv.import_laser_scan_jsonl(
        a.replace(old="123456789", new=stamp),
        "laser",
      )
      is Err(_),
    )
  }
}

///|
test "LaserScan validates every line frame and duplicate keys before output" {
  let text = scan_fixture("[1,2,3]")
  assert_true(@telemetry_csv.import_laser_scan_jsonl(text, "other") is Err(_))
  assert_true(@telemetry_csv.import_laser_scan_jsonl(text, " ") is Err(_))
  assert_true(
    @telemetry_csv.import_laser_scan_jsonl(text, "laser\u{0}") is Err(_),
  )
  assert_true(@telemetry_csv.import_laser_scan_jsonl("\n", "laser") is Err(_))
  assert_true(
    @telemetry_csv.import_laser_scan_jsonl(text + "\n{}", "laser") is Err(_),
  )
  assert_true(
    @telemetry_csv.import_laser_scan_jsonl(
      text.replace(
        old="\"range_min\":0.1",
        new="\"range_min\":0.1,\"range_min\":0.1",
      ),
      "laser",
    )
    is Err(_),
  )
}

///|
test "LaserScan unsupported nonfinite spellings are errors not silent returns" {
  for
    ranges in [
      "[1,NaN,3]", "[1,Infinity,3]", "[1,\"nan\",3]", "[1,true,3]", "[1,{},3]", "[1,1e999,3]",
    ] {
    assert_true(
      @telemetry_csv.import_laser_scan_jsonl(scan_fixture(ranges), "laser")
      is Err(_),
    )
  }
}

///|
test "LaserScan escaping protects frame CSV and SVG while preserving labels" {
  let frame = "laser,<<front>>&&\"\""
  let text = scan_fixture("[1,2,3]").replace(
    old="\"laser\"",
    new=frame.to_json().stringify(),
  )
  let s = @telemetry_csv.import_laser_scan_jsonl(text, frame).unwrap().scans[0]
  assert_true(
    s.to_svg().contains("laser,&lt;&lt;front&gt;&gt;&amp;&amp;&quot;&quot;"),
  )
  assert_true(!s.to_svg().contains("<front>"))
  assert_true(s.to_csv().contains("\"laser,<<front>>&&\"\"\"\"\""))
}

///|
test "LaserScan permits float32 endpoint rounding and singleton scans" {
  assert_true(
    @telemetry_csv.import_laser_scan_jsonl(
      scan_fixture("[1,2,3]", min=-1.57079637, max=1.5707963, step=1.57079637),
      "laser",
    )
    is Ok(_),
  )
  let s = @telemetry_csv.import_laser_scan_jsonl(
      scan_fixture("[0.1]", min=0, max=0, step=0.1),
      "laser",
    ).unwrap().scans[0]
  assert_eq(s.beams[0].x_m, Some(0.1))
  assert_eq(s.beams[0].y_m, Some(0.0))
}
