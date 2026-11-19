///|
test "deployment IMU and saved features match training geometry for23/24 axes and legacy/current contracts" {
  let mount = @aligned.quat_to_mat([0.5, 0.5, -0.5, 0.5])
  let world = @aligned.quat_to_mat([0.5, -0.5, 0.5, 0.5])
  let imu = @sdk_policy.Imu::new({
    quaternion_order: "wxyz",
    orientation_direction: "sensor_to_world",
    gyro_frame: "sensor",
    gyro_to_radians: 0.5,
    sensor_to_body: mount,
    world_to_actor_world: world,
  })
  let mut compared = 0
  for count in [23, 24] {
    let robot = profile(joints=count)
    for legacy in [false, true] {
      let spec : @portable.Spec = {
        format: "lunakine.elu-actor.v1",
        history_frames: 1,
        observation_width: 99,
        encoder: [73, 32],
        decoder: [131, 29],
        observation_norm: {
          mean: Array::make(99, 0.0),
          variance: Array::make(99, 1.0),
          epsilon: 0.01,
        },
        goal_norm: {
          mean: Array::make(73, 0.0),
          variance: Array::make(73, 1.0),
          epsilon: 0.01,
        },
        action_mask: Array::makei(29, i => if i < count { 1.0 } else { 0.0 }),
      }
      let companion : Json = {
        "format": "moonrobo.lunakine-e1.v1",
        "identity": { "robot": Json(robot) },
        "source_spec": {
          "format": "moonrobo.native-tensor-actor-spec.v1",
          "observation_mode": "smc",
          "hist": 1,
          "goal_frames": 1,
        },
        "physical_action_count": count,
        "contract": robot.sensor_contract(legacy~),
      }
      let builder = @deployed.Bundle::parse(Json(spec), companion).smc_observation()
      for sample in 0..<8 {
        let angle = sample.to_double() * 0.19
        let quaternion = [
          @math.cos(angle),
          @math.sin(angle),
          @math.sin(angle * 0.3),
          0.2,
        ]
        let reference = @aligned.quat_to_mat([0.7, 0.1, angle, -0.3])
        let raw_gyro = [angle, 0.5, -1.0]
        let body = @aligned.mat_mul(
          world,
          @aligned.mat_mul(
            @aligned.quat_to_mat(quaternion),
            @aligned.transpose(mount),
          ),
        )
        let gyro = @aligned.mat_vec(mount, raw_gyro).map(value => value * 0.5)
        let gravity = [-body[6], -body[7], -body[8]]
        let orientation = @aligned.mat_to_6d(
          @aligned.mat_mul(@aligned.transpose(body), reference),
        )
        let q = Array::makei(count, i => {
          robot.default_q[i] + @math.sin((sample + i).to_double()) * 0.1
        })
        let qd = Array::makei(count, i => {
          @math.cos((sample + i).to_double()) * 0.3
        })
        let previous = Array::makei(29, i => (i + sample).to_double() * 0.01)
        let expected = robot.observation(
          q,
          qd,
          previous[:count].to_owned(),
          gyro,
          gravity,
          orientation,
        )
        if legacy {
          for i in 29..<58 {
            expected[i] *= 0.1
          }
          for i in 58..<61 {
            expected[i] *= 0.25
          }
        }
        let features = imu.decode(quaternion[:], raw_gyro[:], reference[:])
        let actual = builder.encode(
          q[:],
          qd[:],
          previous[:],
          features.body_gyro()[:],
          features.gravity()[:],
          features.reference_orientation()[:],
        )
        for i in 0..<99 {
          assert_true((actual[i] - expected[i]).abs() < 1.0e-12)
          compared += 1
        }
      }
    }
  }
  assert_eq(compared, 3168)
}
