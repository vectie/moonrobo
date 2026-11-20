///|
fn identity() -> Array[Double] {
  [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]
}

///|
fn close_vector(
  actual : ReadOnlyArray[Double],
  expected : Array[Double],
) -> Unit raise {
  assert_eq(actual.length(), expected.length())
  for index, value in actual {
    assert_true((value - expected[index]).abs() < 1.0e-12)
  }
}

///|
test "IMU conversion respects order direction mounting world alignment gyro frame and units" {
  // R_actor_world<-sdk_world=Ry90; R_body<-sensor=Rz90; measured R_sdk_world<-sensor=Rx90.
  // The resulting body matrix is [-1,0,0; 0,0,-1; 0,-1,0]. These do not commute.
  let mount = [0.0, -1.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0]
  let world = [0.0, 0.0, 1.0, 0.0, 1.0, 0.0, -1.0, 0.0, 0.0]
  let c = 0.5.sqrt()
  for order in ["wxyz", "xyzw"] {
    for direction in ["sensor_to_world", "world_to_sensor"] {
      for gyro_frame in ["sensor", "body", "world"] {
        let imu = @sdk_e1_policy.Imu::new({
          quaternion_order: order,
          orientation_direction: direction,
          gyro_frame,
          gyro_to_radians: 0.5,
          sensor_to_body: mount,
          world_to_actor_world: world,
        })
        let x = if direction == "sensor_to_world" { c } else { -c }
        let quaternion = if order == "wxyz" {
          [c, x, 0.0, 0.0]
        } else {
          [x, 0.0, 0.0, c]
        }
        // Quaternion sign and non-unit magnitude do not change attitude.
        let quaternion = quaternion.map(value => value * -7.3)
        let features = imu.decode(quaternion[:], [1.0, 2.0, 3.0], world[:])
        close_vector(features.gravity(), [0.0, 1.0, 0.0])
        close_vector(features.reference_orientation(), [
          0.0, 0.0, 1.0, 0.0, 0.0, -1.0,
        ])
        close_vector(
          features.body_gyro(),
          match gyro_frame {
            "sensor" => [-1.0, 0.5, 1.5]
            "body" => [0.5, 1.0, 1.5]
            _ => [-1.5, 0.5, -1.0]
          },
        )
      }
    }
  }
}

///|
test "invalid IMU calibration and missing orientation fail without inferred conventions" {
  let original : @sdk_e1_policy.ImuCalibration = {
    quaternion_order: "wxyz",
    orientation_direction: "sensor_to_world",
    gyro_frame: "sensor",
    gyro_to_radians: 1.0,
    sensor_to_body: identity(),
    world_to_actor_world: identity(),
  }
  for
    invalid in [
      { ..original, quaternion_order: "unknown", },
      { ..original, orientation_direction: "unknown", },
      { ..original, gyro_frame: "unknown", },
      { ..original, gyro_to_radians: 0.0, },
      {
        ..original,
        sensor_to_body: [-1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
      },
    ] {
    try @sdk_e1_policy.Imu::new(invalid) catch {
      _ => ()
    } noraise {
      _ => fail("invalid IMU calibration accepted")
    }
  }
  let imu = @sdk_e1_policy.Imu::new(original)
  let mapping = @sdk_e1_policy.Mapping::new(
    fixture(23),
    calibration(23),
    resolve~,
  )
  try @sdk_e1_policy.Observer::new(mapping, imu) catch {
    _ => ()
  } noraise {
    _ => fail("missing saved feature scales were guessed")
  }
  try imu.decode([0.0, 0.0, 0.0, 0.0], [0.0, 0.0, 0.0], identity()[:]) catch {
    _ => ()
  } noraise {
    _ => fail("zero quaternion accepted")
  }
}

///|
test "captured body rotation anchors a stationary reference without changing gravity" {
  let imu = @sdk_e1_policy.Imu::new({
    quaternion_order: "xyzw",
    orientation_direction: "sensor_to_world",
    gyro_frame: "body",
    gyro_to_radians: 1.0,
    sensor_to_body: identity(),
    world_to_actor_world: identity(),
  })
  let q = [0.1, -0.2, 0.3, 0.9]
  let first = imu.decode(q[:], [0.0, 0.0, 0.0], identity()[:])
  let anchored = imu.decode(q[:], [0.0, 0.0, 0.0], first.body_to_world()[:])
  for i, expected in [1.0, 0.0, 0.0, 1.0, 0.0, 0.0] {
    assert_true(
      (anchored.reference_orientation()[i] - expected).abs() < 1.0e-12,
    )
  }
  assert_eq(anchored.gravity()[:].to_owned(), first.gravity()[:].to_owned())
}
