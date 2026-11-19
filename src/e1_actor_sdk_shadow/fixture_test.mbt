///|
fn fixture_actor() -> @actor.Actor raise {
  let spec : @portable.Spec = {
    format: "lunakine.elu-actor.v1",
    history_frames: 2,
    observation_width: 99,
    encoder: [73, 32],
    decoder: [230, 29],
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
    action_mask: Array::makei(29, i => if i < 23 { 1.0 } else { 0.0 }),
  }
  let profile : Json = {
    "format": "moonrobo.e1-embedded-profile.v1",
    "id": "synthetic-readonly",
    "joints": Json(Array::makei(23, i => "joint_\{i}")),
    "default_q": Json(Array::make(23, 0.0)),
    "scales": Json(Array::make(23, 1.0)),
  }
  let bundle = @actor.Bundle::parse(Json(spec), {
    "format": "moonrobo.lunakine-e1.v1",
    "identity": { "robot": profile },
    "source_spec": {
      "format": "moonrobo.native-tensor-actor-spec.v1",
      "observation_mode": "smc",
      "hist": 2,
      "goal_frames": 1,
    },
    "physical_action_count": 23,
    "contract": {
      "profile": profile,
      "internal_actions": 29,
      "physical_actions": 23,
      "observation_mode": "smc",
      "internal_observation_width": 99,
      "joint_velocity_feature_scale": 0.1,
      "body_gyro_feature_scale": 0.25,
    },
  })
  let parameters = Array::make(spec.parameter_count(), 0.0)
  for i in 0..<29 {
    parameters[parameters.length() - 29 + i] = (i + 1).to_double()
  }
  @actor.Actor::reference(bundle, @portable.encode_parameters(parameters[:])[:])
}

///|
fn session(reference_path : String) -> Json {
  {
    "format": "moonrobo.e1-sdk-shadow.v1",
    "catalog_id": "sdk-shadow-fixture",
    "skills": [
      {
        "id": "one",
        "description": "synthetic only",
        "reference_id": "frames",
        "maximum_duration_ms": 1000,
        "parameters": [],
      },
    ],
    "joint_calibration": {
      "format": "moonrobo.e1-sdk-calibration.v1",
      "profile_id": "synthetic-readonly",
      "axes": Json(
        Array::makei(23, i => {
          let axis : Json = {
            "actor_joint": "joint_\{i}",
            "sdk_joint": "fixture_slot_\{23 - i}",
            "motor_id": 123 - i,
            "direction": if i % 2 == 0 {
              -1.0
            } else {
              1.0
            },
            "zero": 0.25,
            "kp": (10 + i).to_double(),
            "kd": (1 + i).to_double(),
          }
          axis
        }),
      ),
      "fixed": [
        {
          "sdk_joint": "fixture_slot_0",
          "motor_id": 100,
          "position": 100.0,
          "velocity": 10.0,
          "torque": 20.0,
          "kp": 30.0,
          "kd": 40.0,
        },
      ],
    },
    "imu_calibration": {
      "quaternion_order": "wxyz",
      "orientation_direction": "sensor_to_world",
      "gyro_frame": "sensor",
      "gyro_to_radians": 1.0,
      "sensor_to_body": [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
      "world_to_actor_world": [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
    },
    "references": [reference_path],
    "maximum_sensor_age_ms": "2000",
  }
}

///|
async fn write_reference(directory : String, bundle : @actor.Bundle) -> String {
  let frame : Json = {
    "goals": Json(Array::make(73, 0.0)),
    "body_to_world": [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
  }
  let value : Json = {
    "format": "moonrobo.e1-actor-reference.v1",
    "profile_id": bundle.profile_id(),
    "joints": Json(bundle.joints()),
    "reference_id": "frames",
    "control_dt_ms": 20,
    "goal_layout": "aligned.preview73.v1",
    "frames": Json([frame, frame, frame]),
  }
  let path = directory + "/reference.json"
  @fs.write_file(path, value.stringify(), create_mode=CreateNew)
  path
}
