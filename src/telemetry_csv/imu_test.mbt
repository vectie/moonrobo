///|
fn imu_recipe(
  timestamp_policy? : String = "exact-milliseconds",
  quaternion_policy? : String = "require-unit",
  groups? : Array[String] = [
    "attitude", "angular_velocity", "linear_acceleration",
  ],
  frame_id? : String = "imu_link",
) -> @telemetry_csv.ImuRecipe {
  { timestamp_policy, quaternion_policy, frame_id, groups, }
}

///|
fn imu_message(
  sec? : Json = 1,
  nanosec? : Json = 0,
  frame? : Json = "imu_link",
  orientation? : Json = { "x": 0, "y": 0, "z": 0, "w": 1 },
  gyro? : Json = { "x": 1, "y": -2, "z": 3 },
  accel? : Json = { "x": 4, "y": 5, "z": 9.81 },
  oc? : Json = [0, 0, 0, 0, 0, 0, 0, 0, 0],
  gc? : Json = [1, -0.1, 0, -0.1, 1, 0, 0, 0, 1],
  ac? : Json = [0, 0, 0, 0, 0, 0, 0, 0, 0],
) -> String {
  (
    {
      "header": {
        "stamp": { "sec": sec, "nanosec": nanosec },
        "frame_id": frame,
      },
      "orientation": orientation,
      "orientation_covariance": oc,
      "angular_velocity": gyro,
      "angular_velocity_covariance": gc,
      "linear_acceleration": accel,
      "linear_acceleration_covariance": ac,
    } : Json).stringify()
}

///|
test "IMU imports identity attitude plus native-unit vectors and source metadata" {
  let text = "\r\n" +
    imu_message() +
    "\r\n\r\n" +
    imu_message(nanosec=100000000)
  let result = @telemetry_csv.import_imu_jsonl(text, imu_recipe()).unwrap()
  assert_eq(result.recording.channels, [
    "imu.roll.rad", "imu.pitch.rad", "imu.yaw.rad", "imu.gyro.x.rad_s", "imu.gyro.y.rad_s",
    "imu.gyro.z.rad_s", "imu.accel.x.m_s2", "imu.accel.y.m_s2", "imu.accel.z.m_s2",
  ])
  assert_eq(result.recording.samples[0].values, [
    0.0, 0.0, 0.0, 1.0, -2.0, 3.0, 4.0, 5.0, 9.81,
  ])
  assert_eq(result.sources[0].source_line_number, 2)
  assert_eq(result.sources[1].source_line_number, 4)
  assert_eq(result.sources[1].frame_id, "imu_link")
  assert_eq(result.sources[0].quaternion_norm, Some(1.0))
  assert_eq(result.sources[0].raw_orientation_xyzw, [0.0, 0.0, 0.0, 1.0])
  assert_eq(result.sources[0].covariance_status["orientation"], "unknown")
  assert_eq(
    result.sources[0].covariance_status["angular_velocity"],
    "provided-unvalidated",
  )
  assert_eq(result.sources[0].covariances["angular_velocity"][1], -0.1)
  assert_eq(
    @telemetry_csv.parse(result.to_csv().unwrap()).unwrap(),
    result.recording,
  )
  assert_eq(
    @telemetry_csv.explore_csv(result.to_csv().unwrap()).unwrap().sample_count,
    2,
  )
}

///|
test "IMU derives known axes and a composite fixed-axis orientation" {
  let cases : Array[(Json, Array[Double])] = [
    (
      { "x": 0, "y": 0, "z": 0.7071067811865476, "w": 0.7071067811865476 },
      [0.0, 0.0, 1.5707963267948966],
    ),
    (
      { "x": 0.7071067811865476, "y": 0, "z": 0, "w": 0.7071067811865476 },
      [1.5707963267948966, 0.0, 0.0],
    ),
    (
      { "x": 0, "y": -0.3826834323650898, "z": 0, "w": 0.9238795325112867 },
      [0.0, -0.7853981633974483, 0.0],
    ),
    (
      {
        "x": 0.3600421736976789,
        "y": -0.19662822552874049,
        "z": 0.463826910250329,
        "w": 0.7852207150935987,
      },
      [0.5235987755982988, -0.6981317007977318, 0.8726646259971648],
    ),
  ]
  for (q, expected) in cases {
    let result = @telemetry_csv.import_imu_jsonl(
      imu_message(orientation=q),
      imu_recipe(groups=["attitude"]),
    ).unwrap()
    for i, value in expected {
      assert_true(
        (result.recording.samples[0].values[i] - value).abs() < 1.0e-12,
      )
    }
  }
}

///|
test "IMU explicit normalization is stable across scale and sign" {
  for scale in [1.0e-250, 2.0, 1.0e250, -2.0] {
    let q : Json = { "x": 0, "y": 0, "z": scale, "w": scale }
    let result = @telemetry_csv.import_imu_jsonl(
      imu_message(orientation=q),
      imu_recipe(quaternion_policy="normalize", groups=[
        "quaternion", "attitude",
      ]),
    ).unwrap()
    let values = result.recording.samples[0].values
    assert_true((values[2].abs() - 0.7071067811865475).abs() < 1.0e-12)
    assert_true((values[6] - 1.5707963267948966).abs() < 1.0e-12)
    assert_eq(result.sources[0].raw_orientation_xyzw[2], scale)
    assert_true(
      @telemetry_csv.import_imu_jsonl(imu_message(orientation=q), imu_recipe())
      is Err(_),
    )
  }
}

///|
test "IMU refuses zero and unreportable quaternion norms" {
  for
    q in [
      ({ "x": 0, "y": 0, "z": 0, "w": 0 } : Json),
      { "x": 1.7e308, "y": 1.7e308, "z": 1.7e308, "w": 1.7e308 },
    ] {
    assert_true(
      @telemetry_csv.import_imu_jsonl(
        imu_message(orientation=q),
        imu_recipe(quaternion_policy="normalize"),
      )
      is Err(_),
    )
  }
}

///|
test "IMU exposes quaternion alternative at both Euler singularities" {
  for y in [-0.7071067811865476, 0.7071067811865476] {
    let text = imu_message(orientation={
      "x": 0,
      "y": y,
      "z": 0,
      "w": 0.7071067811865476,
    })
    guard @telemetry_csv.import_imu_jsonl(text, imu_recipe()) is Err(message) else {
      fail("expected singularity")
    }
    assert_true(message.contains("gimbal lock"))
    let result = @telemetry_csv.import_imu_jsonl(
      text,
      imu_recipe(groups=["quaternion"]),
    ).unwrap()
    assert_eq(result.recording.channels, [
      "imu.q.x", "imu.q.y", "imu.q.z", "imu.q.w",
    ])
  }
}

///|
test "IMU covariance sentinel never becomes a selected zero observation" {
  let unavailable : Json = [-1, 0, 0, 0, 0, 0, 0, 0, 0]
  for
    text in [
      imu_message(oc=unavailable),
      imu_message(gc=unavailable),
      imu_message(ac=unavailable),
    ] {
    guard @telemetry_csv.import_imu_jsonl(text, imu_recipe()) is Err(message) else {
      fail("expected unavailable error")
    }
    assert_true(message.contains("unavailable"))
  }
  let result = @telemetry_csv.import_imu_jsonl(
    imu_message(oc=unavailable, orientation={ "x": 0, "y": 0, "z": 0, "w": 0 }),
    imu_recipe(groups=["angular_velocity"]),
  ).unwrap()
  assert_eq(result.sources[0].quaternion_norm, None)
  assert_eq(result.sources[0].covariance_status["orientation"], "unavailable")
  assert_eq(result.recording.samples[0].values, [1.0, -2.0, 3.0])
}

///|
test "IMU validates unselected vector and covariance shapes and numbers" {
  for
    text in [
      imu_message(gyro={ "x": 1, "y": 2 }),
      imu_message(gyro={ "x": 1, "y": 2, "z": "3" }),
      imu_message(gc=[0]),
      imu_message(gc=[0, 0, 0, 0, "bad", 0, 0, 0, 0]),
      imu_message(orientation={ "x": 0, "y": 0, "z": 0 }),
      imu_message().replace(old="9.81", new="1e999"),
    ] {
    assert_true(
      @telemetry_csv.import_imu_jsonl(text, imu_recipe(groups=["attitude"]))
      is Err(_),
    )
  }
}

///|
test "IMU explicit timestamp precision keeps exact original stamp" {
  let text = imu_message(sec=2147483647, nanosec=999999999)
  assert_true(@telemetry_csv.import_imu_jsonl(text, imu_recipe()) is Err(_))
  let result = @telemetry_csv.import_imu_jsonl(
    text,
    imu_recipe(timestamp_policy="floor-milliseconds"),
  ).unwrap()
  assert_eq(result.recording.samples[0].timestamp_ms, 2147483647999L)
  assert_eq(result.sources[0].nanosec, 999999999)
  assert_eq(result.sources[0].discarded_nanoseconds, 999999)
  assert_true(result.to_json().stringify().contains("\"2147483647999\""))
  for
    bad in [
      imu_message(sec=-1),
      imu_message(sec=2147483648),
      imu_message(sec=1.5),
      imu_message(nanosec=1000000000),
      imu_message(nanosec="0"),
    ] {
    assert_true(@telemetry_csv.import_imu_jsonl(bad, imu_recipe()) is Err(_))
  }
}

///|
test "IMU rejects collisions reversal and late frame changes without partial export" {
  for
    late in [
      imu_message(),
      imu_message(sec=0),
      imu_message(nanosec=999),
      imu_message(nanosec=1000000, frame="other"),
    ] {
    guard @telemetry_csv.import_imu_jsonl(
        imu_message() + "\n\n" + late,
        imu_recipe(timestamp_policy="floor-milliseconds"),
      )
      is Err(message) else {
      fail("expected complete rejection")
    }
    assert_true(message.contains("line 3:"))
  }
}

///|
test "IMU rejects malformed JSON duplicate nested keys and empty recordings" {
  for
    text in [
      "",
      " \r\n",
      "[]",
      "{}",
      "{",
      imu_message().replace(
        old="\"frame_id\":",
        new="\"frame_id\":\"imu_link\",\"frame_id\":",
      ),
      imu_message().replace(old="\"sec\":", new="\"sec\":0,\"sec\":"),
    ] {
    assert_true(@telemetry_csv.import_imu_jsonl(text, imu_recipe()) is Err(_))
  }
}

///|
test "IMU recipe strictness also applies to directly constructed values" {
  for
    recipe in [
      imu_recipe(timestamp_policy="guess"),
      imu_recipe(quaternion_policy="guess"),
      imu_recipe(frame_id=" "),
      imu_recipe(groups=[]),
      imu_recipe(groups=["attitude", "attitude"]),
      imu_recipe(groups=["speed"]),
    ] {
    assert_true(
      @telemetry_csv.import_imu_jsonl(imu_message(), recipe) is Err(_),
    )
    assert_true(
      @telemetry_csv.parse_imu_recipe(recipe.to_json().stringify()) is Err(_),
    )
  }
  let text = imu_recipe().to_json().stringify()
  assert_eq(@telemetry_csv.parse_imu_recipe(text).unwrap(), imu_recipe())
  for
    bad in [
      "{}",
      "[]",
      text.replace(old="\"groups\":", new="\"extra\":0,\"groups\":"),
      text.replace(old="\"groups\":", new="\"groups\":[],\"groups\":"),
    ] {
    assert_true(@telemetry_csv.parse_imu_recipe(bad) is Err(_))
  }
}

///|
test "IMU yaw crossings feed existing gap-aware unwrapping" {
  let a = imu_message(orientation={
    "x": 0,
    "y": 0,
    "z": 0.9961946980917455,
    "w": 0.08715574274765814,
  })
  let b = imu_message(nanosec=100000000, orientation={
    "x": 0,
    "y": 0,
    "z": -0.9961946980917455,
    "w": 0.08715574274765814,
  })
  let imported = @telemetry_csv.import_imu_jsonl(
    a + "\n" + b,
    imu_recipe(groups=["attitude"]),
  ).unwrap()
  let result = @telemetry_csv.unwrap_csv(
    imported.to_csv().unwrap(),
    [
      {
        source: "imu.yaw.rad",
        target: "imu.yaw.continuous.rad",
        period: 6.283185307179586,
        unit: "rad",
      },
    ],
    max_gap_ms=500L,
  ).unwrap()
  assert_true(
    (result.recording.samples[1].values[2] - 3.3161255787892263).abs() < 1.0e-12,
  )
  assert_eq(result.segment_count, 1)
}
