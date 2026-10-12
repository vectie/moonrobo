///|
fn jsonl_recipe() -> @telemetry_csv.JsonlRecipe {
  {
    timestamp_path: ["clock", "ms"],
    channels: [
      { path: ["pose", "y"], target: "y.m", unit: "m", },
      { path: ["pose", "x"], target: "x.m", unit: "m", },
    ],
  }
}

///|
test "JSONL preserves exact timestamps recipe order and physical source lines" {
  let source = "\r\n{\"clock\":{\"ms\":\"9007199254740993\"},\"pose\":{\"x\":3,\"y\":4},\"ignored\":null}\r\n\r\n{\"clock\":{\"ms\":\"9223372036854775807\"},\"pose\":{\"x\":6,\"y\":8}}\r\n"
  let imported = @telemetry_csv.import_jsonl(source, jsonl_recipe()).unwrap()
  assert_eq(imported.format, "moonrobo.telemetry-jsonl.v1")
  assert_eq(imported.timebase, "milliseconds-as-recorded")
  assert_eq(imported.recording.channels, ["y.m", "x.m"])
  assert_eq(imported.source_line_numbers, [2, 4])
  assert_eq(imported.recording.samples[0].timestamp_ms, 9007199254740993L)
  assert_eq(imported.recording.samples[1].timestamp_ms, 9223372036854775807L)
  assert_eq(imported.recording.samples[0].values, [4.0, 3.0])
  assert_eq(imported.recording.samples[1].values, [8.0, 6.0])
  assert_eq(imported.recipe, jsonl_recipe())
  assert_eq(
    @telemetry_csv.parse(imported.to_csv().unwrap()).unwrap(),
    imported.recording,
  )
  assert_true(
    imported.to_json().stringify().contains("\"9223372036854775807\""),
  )
}

///|
test "JSONL paths are literal keys including punctuation Unicode and empty key" {
  let recipe = @telemetry_csv.parse_jsonl_recipe(
    "{\"timestamp_path\":[\"time.ms\"],\"channels\":[{\"path\":[\"a/b~c\",\"\",\"温度\"],\"target\":\"温度.c\",\"unit\":\" °C \"}]}",
  ).unwrap()
  let result = @telemetry_csv.import_jsonl(
    "{\"time.ms\":\"0001\",\"a/b~c\":{\"\":{\"温度\":-2.5e1}},\"unselected\":[null,true,\"text\"]}",
    recipe,
  ).unwrap()
  assert_eq(result.recording.samples[0].timestamp_ms, 1L)
  assert_eq(result.recording.samples[0].values, [-25.0])
  assert_eq(result.recipe.channels[0].unit, " °C ")
  assert_eq(
    @telemetry_csv.parse(result.to_csv().unwrap()).unwrap(),
    result.recording,
  )
}

///|
test "JSONL timestamp strings reject numeric coercion negative fractional and overflow" {
  let recipe : @telemetry_csv.JsonlRecipe = {
    timestamp_path: ["t"],
    channels: [{ path: ["v"], target: "v", unit: "unspecified", }],
  }
  for
    raw in [
      "0", "9007199254740993", "null", "true", "\"\"", "\"-1\"", "\"+1\"", "\"1.0\"",
      "\"1e3\"", "\" 1\"", "\"1 \"", "\"9223372036854775808\"", "\"١\"",
    ] {
    assert_true(
      @telemetry_csv.import_jsonl("{\"t\":" + raw + ",\"v\":1}", recipe)
      is Err(_),
    )
  }
  assert_eq(
    @telemetry_csv.import_jsonl("{\"t\":\"0\",\"v\":1}", recipe).unwrap().recording.samples[0].timestamp_ms,
    0L,
  )
}

///|
test "JSONL nested missing and nonobject errors identify source line and channel" {
  let good = "{\"clock\":{\"ms\":\"0\"},\"pose\":{\"x\":0,\"y\":0}}\n\n"
  for
    (bad, expected) in [
      (
        "{\"clock\":{\"ms\":\"1\"},\"pose\":{\"x\":1}}", "line 3: y.m: missing object key \"y\"",
      ),
      (
        "{\"clock\":{\"ms\":\"1\"},\"pose\":null}", "line 3: y.m: path traverses a non-object",
      ),
      (
        "{\"clock\":{\"ms\":\"1\"},\"pose\":[1,2]}", "line 3: y.m: path traverses a non-object",
      ),
      (
        "{\"pose\":{\"x\":1,\"y\":2}}", "line 3: timestamp: missing object key \"clock\"",
      ),
      (
        "{\"clock\":1,\"pose\":{\"x\":1,\"y\":2}}", "line 3: timestamp: path traverses a non-object",
      ),
    ] {
    assert_eq(
      @telemetry_csv.import_jsonl(good + bad, jsonl_recipe()),
      Err(expected),
    )
  }
}

///|
test "JSONL channel values must be finite numbers without string or boolean coercion" {
  for raw in ["null", "true", "\"1\"", "[]", "{}", "1e400", "-1e400"] {
    assert_true(
      @telemetry_csv.import_jsonl(
        "{\"clock\":{\"ms\":\"0\"},\"pose\":{\"x\":0,\"y\":" + raw + "}}",
        jsonl_recipe(),
      )
      is Err(_),
    )
  }
  let result = @telemetry_csv.import_jsonl(
    "{\"clock\":{\"ms\":\"0\"},\"pose\":{\"x\":1.7976931348623157e308,\"y\":-5e-324}}",
    jsonl_recipe(),
  ).unwrap()
  assert_eq(result.recording.samples[0].values, [
    -5.0e-324, 1.7976931348623157e308,
  ])
  assert_eq(
    @telemetry_csv.parse(result.to_csv().unwrap()).unwrap(),
    result.recording,
  )
}

///|
test "JSONL rejects empty malformed nonobject and late invalid records" {
  let good = "{\"clock\":{\"ms\":\"0\"},\"pose\":{\"x\":0,\"y\":0}}"
  for
    source in [
      "",
      " \r\n\n",
      "[]",
      "null",
      "1",
      "{}{}",
      "{\n\"clock\":{}}",
      good + "\nnot JSON",
      good + "\n[]",
      good + "\n{\"extra\":NaN}",
    ] {
    assert_true(@telemetry_csv.import_jsonl(source, jsonl_recipe()) is Err(_))
  }
}

///|
test "JSONL does not reorder or deduplicate timestamps" {
  let first = "{\"clock\":{\"ms\":\"10\"},\"pose\":{\"x\":0,\"y\":0}}\n"
  for stamp in ["10", "9", "00010"] {
    assert_eq(
      @telemetry_csv.import_jsonl(
        first +
        "{\"clock\":{\"ms\":\"" +
        stamp +
        "\"},\"pose\":{\"x\":1,\"y\":2}}",
        jsonl_recipe(),
      ),
      Err("line 2: timestamps must strictly increase"),
    )
  }
}

///|
test "JSONL recipe rejects unknown missing wrongly typed and empty field selections" {
  for
    text in [
      "not json", "[]", "{}", "{\"timestamp_path\":[\"t\"],\"channels\":[]}", "{\"timestamp_path\":[],\"channels\":[{\"path\":[\"v\"],\"target\":\"v\",\"unit\":\"u\"}]}",
      "{\"timestamp_path\":\"t\",\"channels\":[{\"path\":[\"v\"],\"target\":\"v\",\"unit\":\"u\"}]}",
      "{\"timestamp_path\":[\"t\"],\"channels\":[{\"path\":[\"v\"],\"target\":\"v\",\"unit\":\"u\"}],\"extra\":1}",
      "{\"timestamp_path\":[\"t\"],\"channels\":[{\"path\":[\"v\"],\"target\":\"v\",\"typo\":\"u\"}]}",
      "{\"timestamp_path\":[\"t\"],\"channels\":[{\"path\":[\"v\"],\"target\":\"v\",\"unit\":\"u\",\"extra\":1}]}",
      "{\"timestamp_path\":[\"t\"],\"channels\":[{\"path\":[0],\"target\":\"v\",\"unit\":\"u\"}]}",
      "{\"timestamp_path\":[\"t\"],\"channels\":[{\"path\":[],\"target\":\"v\",\"unit\":\"u\"}]}",
      "{\"timestamp_path\":[\"t\"],\"channels\":[{\"path\":[\"v\"],\"target\":\"v\",\"unit\":\" \"}]}",
    ] {
    assert_true(@telemetry_csv.parse_jsonl_recipe(text) is Err(_))
  }
}

///|
test "JSONL API validates direct recipes names and duplicate targets" {
  let source = "{\"t\":\"1\",\"v\":2}"
  for target in ["", "timestamp_ms", " v", "v ", "v,w", "v\"w", "v\nw", "v\rw"] {
    assert_true(
      @telemetry_csv.import_jsonl(source, {
        timestamp_path: ["t"],
        channels: [{ path: ["v"], target, unit: "u", }],
      })
      is Err(_),
    )
  }
  let invalid : Array[@telemetry_csv.JsonlRecipe] = [
    {
      timestamp_path: [],
      channels: [{ path: ["v"], target: "v", unit: "u", }],
    },
    { timestamp_path: ["t"], channels: [], },
    {
      timestamp_path: ["t"],
      channels: [{ path: [], target: "v", unit: "u", }],
    },
    {
      timestamp_path: ["t"],
      channels: [{ path: ["v"], target: "v", unit: " ", }],
    },
    {
      timestamp_path: ["t"],
      channels: [
        { path: ["v"], target: "v", unit: "u", },
        { path: ["v"], target: "v", unit: "u", },
      ],
    },
  ]
  for recipe in invalid {
    assert_true(@telemetry_csv.import_jsonl(source, recipe) is Err(_))
  }
}

///|
test "JSONL output feeds existing exploration plot and trajectory deterministically" {
  let source = "{\"clock\":{\"ms\":\"9007199254740993\"},\"pose\":{\"x\":0,\"y\":0}}\n{\"clock\":{\"ms\":\"9007199254741093\"},\"pose\":{\"x\":3,\"y\":4}}"
  let imported = @telemetry_csv.import_jsonl(source, jsonl_recipe()).unwrap()
  let csv = imported.to_csv().unwrap()
  assert_eq(@telemetry_csv.explore_csv(csv).unwrap().sample_count, 2)
  let plot = @telemetry_csv.plot_csv(csv, ["x.m", "y.m"], unit_labels=["m", "m"]).unwrap()
  assert_eq(plot.samples.length(), 2)
  assert_eq(plot.samples[0].timestamp_ms, 9007199254740993L)
  assert_eq(
    @telemetry_csv.trajectory_csv(csv, "x.m", "y.m", units="m").unwrap().observed_distance,
    5.0,
  )
  assert_eq(
    @telemetry_csv.import_jsonl(source, jsonl_recipe())
    .unwrap()
    .to_csv()
    .unwrap(),
    csv,
  )
}

///|
test "JSONL rejects duplicate object keys including escaped aliases and recipe fields" {
  for
    source in [
      "{\"clock\":{\"ms\":\"0\",\"ms\":\"1\"},\"pose\":{\"x\":0,\"y\":0}}", "{\"clock\":{\"ms\":\"0\"},\"pose\":{\"x\":0,\"\\u0078\":1,\"y\":0}}",
      "{\"clock\":{\"ms\":\"0\"},\"pose\":{\"x\":0,\"y\":0},\"unused\":[{\"k\":1,\"k\":2}]}",
    ] {
    assert_true(@telemetry_csv.import_jsonl(source, jsonl_recipe()) is Err(_))
  }
  assert_true(
    @telemetry_csv.parse_jsonl_recipe(
      "{\"timestamp_path\":[\"a\"],\"timestamp_path\":[\"b\"],\"channels\":[{\"path\":[\"v\"],\"target\":\"v\",\"unit\":\"u\"}]}",
    )
    is Err(_),
  )
  let source = "{\"clock\":{\"ms\":\"0\"},\"pose\":{\"x\":0,\"y\":0},\"unused\":[{\"x\":1},{\"x\":2}],\"tricky\":\"\\\"}:\\\\\",\"a\\\"b\":{\"a\\\"b\":1}}"
  assert_true(@telemetry_csv.import_jsonl(source, jsonl_recipe()) is Ok(_))
}
