///|
fn joint_recipe(
  policy? : String = "exact-milliseconds",
) -> @telemetry_csv.JointStateRecipe {
  {
    timestamp_policy: policy,
    channels: [
      {
        joint: "elbow",
        field: "velocity",
        target: "elbow.rad_s",
        unit: "rad/s",
      },
      {
        joint: "shoulder",
        field: "position",
        target: "shoulder.rad",
        unit: "rad",
      },
    ],
  }
}

///|
fn joint_message(
  sec? : Json = 1,
  nanosec? : Json = 0,
  names? : Json = ["shoulder", "elbow"],
  position? : Json = [1, 2],
  velocity? : Json = [3, 4],
  effort? : Json = [],
) -> String {
  (
    {
      "header": {
        "stamp": { "sec": sec, "nanosec": nanosec },
        "frame_id": "base",
      },
      "name": names,
      "position": position,
      "velocity": velocity,
      "effort": effort,
    } : Json).stringify()
}

///|
test "JointState maps reordered joint arrays and retains physical source lines" {
  let text = "\r\n" +
    joint_message() +
    "\r\n\r\n" +
    joint_message(
      nanosec=250000000,
      names=["elbow", "shoulder"],
      position=[20, 10],
      velocity=[40, 30],
    )
  let imported = @telemetry_csv.import_joint_state_jsonl(text, joint_recipe()).unwrap()
  assert_eq(imported.format, "moonrobo.ros2-joint-state-import.v1")
  assert_eq(imported.recording.channels, ["elbow.rad_s", "shoulder.rad"])
  assert_eq(imported.recording.samples[0].values, [4.0, 1.0])
  assert_eq(imported.recording.samples[1].values, [40.0, 10.0])
  assert_eq(imported.recording.samples[0].timestamp_ms, 1000L)
  assert_eq(imported.recording.samples[1].timestamp_ms, 1250L)
  assert_eq(imported.sources[0].source_line_number, 2)
  assert_eq(imported.sources[1].source_line_number, 4)
  assert_eq(imported.sources[0].joint_indices, [1, 0])
  assert_eq(imported.sources[1].joint_indices, [0, 1])
  assert_eq(imported.sources[1].frame_id, "base")
  assert_eq(imported.recipe, joint_recipe())
  assert_eq(
    @telemetry_csv.parse(imported.to_csv().unwrap()).unwrap(),
    imported.recording,
  )
  let explored = @telemetry_csv.explore_csv(imported.to_csv().unwrap()).unwrap()
  assert_eq(explored.sample_count, 2)
  assert_eq(explored.summaries[0].maximum, 40.0)
}

///|
test "JointState floors only explicitly and retains discarded nanoseconds" {
  let source = joint_message(sec=2147483647, nanosec=999999999)
  assert_true(
    @telemetry_csv.import_joint_state_jsonl(source, joint_recipe()) is Err(_),
  )
  let imported = @telemetry_csv.import_joint_state_jsonl(
    source,
    joint_recipe(policy="floor-milliseconds"),
  ).unwrap()
  assert_eq(imported.recording.samples[0].timestamp_ms, 2147483647999L)
  assert_eq(imported.sources[0].sec, 2147483647)
  assert_eq(imported.sources[0].nanosec, 999999999)
  assert_eq(imported.sources[0].discarded_nanoseconds, 999999)
  assert_true(imported.to_json().stringify().contains("\"2147483647999\""))
  assert_eq(
    @telemetry_csv.parse(imported.to_csv().unwrap()).unwrap(),
    imported.recording,
  )
  let exact = @telemetry_csv.import_joint_state_jsonl(
    joint_message(sec=0),
    joint_recipe(),
  ).unwrap()
  assert_eq(exact.recording.samples[0].timestamp_ms, 0L)
}

///|
test "JointState refuses rounding collisions duplicate timestamps and clock reset" {
  for
    pair in [
      joint_message() + "\n" + joint_message(nanosec=999999),
      joint_message() + "\n" + joint_message(),
      joint_message(sec=2) + "\n" + joint_message(sec=1),
    ] {
    let result = @telemetry_csv.import_joint_state_jsonl(
      pair,
      joint_recipe(policy="floor-milliseconds"),
    )
    guard result is Err(message) else { fail("expected timestamp failure") }
    assert_true(
      message.contains("line 2:") && message.contains("strictly increase"),
    )
  }
}

///|
test "JointState accepts empty unused fields and refuses missing selected data" {
  let recipe : @telemetry_csv.JointStateRecipe = {
    timestamp_policy: "exact-milliseconds",
    channels: [
      { joint: "elbow", field: "effort", target: "torque", unit: "Nm", },
    ],
  }
  let source = joint_message(position=[], velocity=[], effort=[3, -2])
  assert_eq(
    @telemetry_csv.import_joint_state_jsonl(source, recipe).unwrap().recording.samples[0].values,
    [-2.0],
  )
  assert_true(
    @telemetry_csv.import_joint_state_jsonl(joint_message(), recipe) is Err(_),
  )
  assert_true(
    @telemetry_csv.import_joint_state_jsonl(
      joint_message(names=["shoulder", "wrist"]),
      joint_recipe(),
    )
    is Err(_),
  )
}

///|
test "JointState validates unselected arrays and all source messages" {
  for
    bad in [
      joint_message(effort=[1]),
      joint_message(effort=[1, "bad"]),
      joint_message(position=[1]),
      joint_message(velocity=null),
      joint_message(names=["elbow", "elbow"]),
      joint_message(names=["", "elbow"]),
      joint_message(names=[]),
      joint_message(names=["elbow", 2]),
    ] {
    let result = @telemetry_csv.import_joint_state_jsonl(
      joint_message(sec=0) + "\n\n" + bad,
      joint_recipe(),
    )
    guard result is Err(message) else { fail("expected invalid late row") }
    assert_true(message.has_prefix("line 3:"))
  }
}

///|
test "JointState enforces ROS 2 timestamp ranges integers and spelling" {
  for bad in ([-1, 2147483648, 0.5, "1", null, true] : Array[Json]) {
    assert_true(
      @telemetry_csv.import_joint_state_jsonl(
        joint_message(sec=bad),
        joint_recipe(),
      )
      is Err(_),
    )
  }
  for bad in ([-1, 1000000000, 0.5, "0", null, true] : Array[Json]) {
    assert_true(
      @telemetry_csv.import_joint_state_jsonl(
        joint_message(nanosec=bad),
        joint_recipe(),
      )
      is Err(_),
    )
  }
  for
    bad in [
      "{}", "[]", "null", "{bad", "", "\n\r\n", "{\"header\":{\"stamp\":{\"secs\":1,\"nsecs\":0},\"frame_id\":\"\"},\"name\":[\"elbow\"],\"position\":[1],\"velocity\":[2],\"effort\":[]}",
    ] {
    assert_true(
      @telemetry_csv.import_joint_state_jsonl(bad, joint_recipe()) is Err(_),
    )
  }
}

///|
test "JointState duplicate JSON keys and nonfinite numeric arrays fail" {
  let good = joint_message()
  for
    bad in [
      good.replace(old="\"sec\":1", new="\"sec\":0,\"sec\":1"),
      good.replace(
        old="\"frame_id\":\"base\"",
        new="\"frame_id\":\"base\",\"frame_id\":\"other\"",
      ),
      good.replace(old="\"effort\":[]", new="\"effort\":[1e999,0]"),
    ] {
    assert_true(bad != good)
    assert_true(
      @telemetry_csv.import_joint_state_jsonl(bad, joint_recipe()) is Err(_),
    )
  }
}

///|
test "JointState literal Unicode joint selection and descriptive labels" {
  let recipe = @telemetry_csv.parse_joint_state_recipe(
    "{\"timestamp_policy\":\"exact-milliseconds\",\"channels\":[{\"joint\":\"肘.a/b\",\"field\":\"position\",\"target\":\"肘.rad\",\"unit\":\" rad \"}]}",
  ).unwrap()
  let imported = @telemetry_csv.import_joint_state_jsonl(
    joint_message(names=["shoulder", "肘.a/b"]),
    recipe,
  ).unwrap()
  assert_eq(imported.recording.samples[0].values, [2.0])
  assert_eq(imported.recipe.channels[0].unit, " rad ")
  assert_eq(
    @telemetry_csv.parse(imported.to_csv().unwrap()).unwrap(),
    imported.recording,
  )
}

///|
test "JointState recipe requires explicit policy and unambiguous mapping" {
  let good = joint_recipe().to_json().stringify()
  assert_eq(
    @telemetry_csv.parse_joint_state_recipe(good).unwrap(),
    joint_recipe(),
  )
  for
    bad in [
      "{}",
      "[]",
      "null",
      "bad",
      good.replace(old="exact-milliseconds", new="guess"),
      good.replace(old="\"timestamp_policy\":\"exact-milliseconds\",", new=""),
      good.replace(
        old="\"timestamp_policy\":",
        new="\"extra\":0,\"timestamp_policy\":",
      ),
      good.replace(old="\"velocity\"", new="\"acceleration\""),
      good.replace(old="\"elbow.rad_s\"", new="\"shoulder.rad\""),
      good.replace(old="\"elbow.rad_s\"", new="\"timestamp_ms\""),
      good.replace(old="\"elbow.rad_s\"", new="\"bad,name\""),
      good.replace(old="\"elbow\"", new="\" \""),
      good.replace(old="\"rad/s\"", new="\" \""),
      good.replace(
        old="\"joint\":\"elbow\"",
        new="\"joint\":\"elbow\",\"extra\":1",
      ),
      good.replace(
        old="\"joint\":\"elbow\"",
        new="\"joint\":\"elbow\",\"joint\":\"shoulder\"",
      ),
    ] {
    assert_true(bad != good)
    assert_true(@telemetry_csv.parse_joint_state_recipe(bad) is Err(_))
  }
  let recipe = joint_recipe()
  recipe.channels.push(recipe.channels[0])
  assert_true(
    @telemetry_csv.import_joint_state_jsonl(joint_message(), recipe) is Err(_),
  )
}
