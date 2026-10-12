///|
fn odom_recipe(
  timestamp_policy? : String = "exact-milliseconds",
  quaternion_policy? : String = "require-unit",
  frame_id? : String = "odom",
  child_frame_id? : String = "base_link",
  groups? : Array[String] = [
    "position", "attitude", "linear_velocity", "angular_velocity",
  ],
) -> @telemetry_csv.OdometryRecipe {
  { timestamp_policy, quaternion_policy, frame_id, child_frame_id, groups, }
}

///|
fn odom_message(
  sec? : Json = 1,
  ns? : Json = 0,
  frame? : Json = "odom",
  child? : Json = "base_link",
  position? : Json = { "x": 3, "y": 4, "z": 0 },
  orientation? : Json = { "x": 0, "y": 0, "z": 0, "w": 1 },
  linear? : Json = { "x": 1, "y": -2, "z": 3 },
  angular? : Json = { "x": 4, "y": 5, "z": 6 },
  pc? : Json,
  tc? : Json,
) -> String {
  let covariance = Array::make(36, 0.0).to_json()
  (
    {
      "header": { "stamp": { "sec": sec, "nanosec": ns }, "frame_id": frame },
      "child_frame_id": child,
      "pose": {
        "pose": { "position": position, "orientation": orientation },
        "covariance": pc.or(covariance),
      },
      "twist": {
        "twist": { "linear": linear, "angular": angular },
        "covariance": tc.or(covariance),
      },
    } : Json).stringify()
}

///|
test "Odometry preserves different frames and raw covariance while exporting selected channels" {
  let covariance = Array::make(36, 0.0)
  covariance[0] = -1.0
  covariance[1] = -0.25
  covariance[35] = 9.0
  let text = "\n" +
    odom_message(pc=covariance.to_json()) +
    "\n\n" +
    odom_message(ns=100000000)
  let imported = @telemetry_csv.import_odometry_jsonl(text, odom_recipe()).unwrap()
  assert_eq(imported.recording.channels, [
    "odom.pose.x.m", "odom.pose.y.m", "odom.pose.z.m", "odom.pose.roll.rad", "odom.pose.pitch.rad",
    "odom.pose.yaw.rad", "odom.twist.linear.x.m_s", "odom.twist.linear.y.m_s", "odom.twist.linear.z.m_s",
    "odom.twist.angular.x.rad_s", "odom.twist.angular.y.rad_s", "odom.twist.angular.z.rad_s",
  ])
  assert_eq(imported.recording.samples[0].values, [
    3.0, 4.0, 0.0, 0.0, 0.0, 0.0, 1.0, -2.0, 3.0, 4.0, 5.0, 6.0,
  ])
  assert_eq(imported.channel_frames["odom.pose.yaw.rad"], "odom")
  assert_eq(imported.channel_frames["odom.twist.linear.x.m_s"], "base_link")
  assert_eq(imported.sources[0].source_line_number, 2)
  assert_eq(imported.sources[1].source_line_number, 4)
  assert_eq(imported.sources[0].pose_covariance, covariance)
  assert_eq(imported.sources[0].twist_covariance.length(), 36)
  assert_eq(imported.sources[0].quaternion_norm, 1.0)
  assert_eq(
    @telemetry_csv.parse(imported.to_csv().unwrap()).unwrap(),
    imported.recording,
  )
}

///|
test "Odometry does not rotate body twist into the pose frame" {
  let imported = @telemetry_csv.import_odometry_jsonl(
    odom_message(orientation={
      "x": 0,
      "y": 0,
      "z": 0.7071067811865476,
      "w": 0.7071067811865476,
    }),
    odom_recipe(groups=["linear_velocity", "attitude", "quaternion"]),
  ).unwrap()
  let values = imported.recording.samples[0].values
  assert_eq(values[0], 1.0)
  assert_eq(values[1], -2.0)
  assert_true((values[5] - 1.5707963267948966).abs() < 1.0e-12)
  assert_true((values[8] - 0.7071067811865476).abs() < 1.0e-12)
  assert_eq(imported.recording.channels[0], "odom.twist.linear.x.m_s")
}

///|
test "Odometry has explicit normalization and quaternion alternative for Euler singularity" {
  let scaled = odom_message(orientation={ "x": 0, "y": 0, "z": 2, "w": 2 })
  assert_true(
    @telemetry_csv.import_odometry_jsonl(scaled, odom_recipe()) is Err(_),
  )
  let result = @telemetry_csv.import_odometry_jsonl(
    scaled,
    odom_recipe(quaternion_policy="normalize"),
  ).unwrap()
  assert_eq(result.sources[0].raw_orientation_xyzw, [0.0, 0.0, 2.0, 2.0])
  assert_true(
    (result.sources[0].quaternion_norm - 2.8284271247461903).abs() < 1.0e-12,
  )
  let singular = odom_message(orientation={
    "x": 0,
    "y": 0.7071067811865476,
    "z": 0,
    "w": 0.7071067811865476,
  })
  assert_true(
    @telemetry_csv.import_odometry_jsonl(singular, odom_recipe()) is Err(_),
  )
  assert_true(
    @telemetry_csv.import_odometry_jsonl(
      singular,
      odom_recipe(groups=["quaternion"]),
    )
    is Ok(_),
  )
  assert_true(
    @telemetry_csv.import_odometry_jsonl(
      odom_message(orientation={ "x": 0, "y": 0, "z": 0, "w": 0 }),
      odom_recipe(groups=["position"]),
    )
    is Err(_),
  )
}

///|
test "Odometry validates unselected nested fields and both covariance arrays" {
  let bad_covariance = Array::make(36, (0 : Json))
  bad_covariance[30] = "unknown"
  for
    text in [
      odom_message(linear={ "x": 1, "y": 2 }),
      odom_message(angular={ "x": 1, "y": 2, "z": "3" }),
      odom_message(position={ "x": 1, "y": 2 }),
      odom_message(pc=[0]),
      odom_message(tc=bad_covariance.to_json()),
      odom_message(angular={ "x": 9.81, "y": 0, "z": 0 }).replace(
        old="9.81",
        new="1e999",
      ),
    ] {
    assert_true(
      @telemetry_csv.import_odometry_jsonl(
        text,
        odom_recipe(groups=["quaternion"]),
      )
      is Err(_),
    )
  }
}

///|
test "Odometry precision retains exact stamps and rejects collisions or changed frames" {
  let text = odom_message(sec=2147483647, ns=999999999)
  assert_true(
    @telemetry_csv.import_odometry_jsonl(text, odom_recipe()) is Err(_),
  )
  let result = @telemetry_csv.import_odometry_jsonl(
    text,
    odom_recipe(timestamp_policy="floor-milliseconds"),
  ).unwrap()
  assert_eq(result.recording.samples[0].timestamp_ms, 2147483647999L)
  assert_eq(result.sources[0].nanosec, 999999999)
  assert_eq(result.sources[0].discarded_nanoseconds, 999999)
  for
    late in [
      odom_message(),
      odom_message(sec=0),
      odom_message(ns=999),
      odom_message(ns=1000000, frame="map"),
      odom_message(ns=1000000, child="other"),
    ] {
    guard @telemetry_csv.import_odometry_jsonl(
        odom_message() + "\n\n" + late,
        odom_recipe(timestamp_policy="floor-milliseconds"),
      )
      is Err(message) else {
      fail("expected complete rejection")
    }
    assert_true(message.contains("line 3:"))
  }
  for
    bad in [
      odom_message(sec=-1),
      odom_message(sec=1.5),
      odom_message(ns=1000000000),
    ] {
    assert_true(
      @telemetry_csv.import_odometry_jsonl(bad, odom_recipe()) is Err(_),
    )
  }
}

///|
test "Odometry rejects malformed and duplicate keys while allowing blank lines" {
  for
    text in [
      "",
      " \r\n",
      "[]",
      "{}",
      "{",
      odom_message().replace(
        old="\"child_frame_id\":",
        new="\"child_frame_id\":\"base_link\",\"child_frame_id\":",
      ),
      odom_message().replace(old="\"sec\":", new="\"sec\":0,\"sec\":"),
    ] {
    assert_true(
      @telemetry_csv.import_odometry_jsonl(text, odom_recipe()) is Err(_),
    )
  }
  assert_true(
    @telemetry_csv.import_odometry_jsonl(
      "\r\n" + odom_message() + "\r\n",
      odom_recipe(),
    )
    is Ok(_),
  )
}

///|
test "Odometry recipe is strict for both JSON and direct API callers" {
  let text = odom_recipe().to_json().stringify()
  assert_eq(@telemetry_csv.parse_odometry_recipe(text).unwrap(), odom_recipe())
  for
    recipe in [
      odom_recipe(timestamp_policy="guess"),
      odom_recipe(quaternion_policy="guess"),
      odom_recipe(frame_id=" "),
      odom_recipe(child_frame_id=""),
      odom_recipe(groups=[]),
      odom_recipe(groups=["position", "position"]),
      odom_recipe(groups=["speed"]),
    ] {
    assert_true(
      @telemetry_csv.import_odometry_jsonl(odom_message(), recipe) is Err(_),
    )
    assert_true(
      @telemetry_csv.parse_odometry_recipe(recipe.to_json().stringify())
      is Err(_),
    )
  }
  for
    bad in [
      "{}",
      "[]",
      text.replace(old="\"groups\":", new="\"extra\":0,\"groups\":"),
      text.replace(old="\"groups\":", new="\"groups\":[],\"groups\":"),
    ] {
    assert_true(@telemetry_csv.parse_odometry_recipe(bad) is Err(_))
  }
}

///|
test "Odometry CSV feeds the existing gap-aware spatial trajectory" {
  let text = odom_message(position={ "x": 0, "y": 0, "z": 0 }) +
    "\n" +
    odom_message(sec=2) +
    "\n" +
    odom_message(sec=5, position={ "x": 99, "y": 99, "z": 0 })
  let imported = @telemetry_csv.import_odometry_jsonl(
    text,
    odom_recipe(groups=["position"]),
  ).unwrap()
  let path = @telemetry_csv.trajectory_csv(
    imported.to_csv().unwrap(),
    "odom.pose.x.m",
    "odom.pose.y.m",
    units="m",
  ).unwrap()
  assert_eq(path.observed_distance, 5.0)
  assert_eq(path.gap_count, 1)
  assert_eq(path.points.length(), 3)
}
