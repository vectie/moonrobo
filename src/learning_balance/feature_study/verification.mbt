///|
fn field(value : Json, key : String) -> Json raise {
  guard value is Object(fields) && fields.get(key) is Some(result) else {
    fail("missing feature study field: " + key)
  }
  result
}

///|
fn number(value : Json, key : String) -> Double raise {
  @json.from_json(field(value, key))
}

///|
pub fn errors(
  actual : Array[Array[Double]],
  expected : Array[Array[Double]],
) -> Json raise {
  guard !actual.is_empty() && actual.length() == expected.length() else {
    fail("misaligned feature comparison")
  }
  let mut squared = 0.0
  let mut maximum = 0.0
  let mut count = 0
  for i, row in actual {
    guard row.length() == expected[i].length() else {
      fail("feature comparison channel layout differs")
    }
    for j, x in row {
      let d = x - expected[i][j]
      squared += d * d
      maximum = @balance.clip(d.abs(), maximum, 1.0 / 0.0)
      count += 1
    }
  }
  {
    "count": count.to_json(),
    "squared_error": squared.to_json(),
    "maximum_error": maximum.to_json(),
    "rmse": (squared / count.to_double()).sqrt().to_json(),
  }
}

///|
pub fn random_geometry(
  runtime : @native_physics.Runtime,
  geometry : @balance.Kinematics,
  count : Int32,
  seed : UInt32,
) -> Json raise {
  let rng = @numeric.Rng::new(seed)
  let (_, _, _, nu) = runtime.dimensions()
  let predicted : Array[Array[Double]] = []
  let predicted32 : Array[Array[Double]] = []
  let truth : Array[Array[Double]] = []
  let monitor = @balance_native.NativeBalanceTeacher::new(
    runtime,
    {
      angle_gain: 0.0,
      rate_gain: 0.0,
      com_gain: 0.0,
      velocity_gain: 0.0,
      pitch_bias: 0.0,
      joint_damping: 0.0,
      residual_bound: 0.3,
      hip_share: 0.0,
      waist_share: 0.0,
      waist_dynamic_only: false,
      support_gain: 0.0,
    },
    0.02,
  )
  for _ in 0..<count {
    runtime.reset("home", 0.8)
    let state = runtime.state()
    for j in 0..<3 {
      state[j] = -20.0 + 40.0 * rng.uniform()
    }
    let q = Array::makei(4, fn(_) { rng.normal() })
    let norm = @balance.dot(q, q).sqrt()
    for j in 0..<4 {
      state[3 + j] = q[j] / norm
    }
    for i in runtime.q_indices() {
      state[i] += -0.15 + 0.3 * rng.uniform()
    }
    runtime.set_state(state)
    let (rotation, feet, com) = monitor.measurements()
    let error = [
      com[0] - (feet[0][0] + feet[1][0]) / 2.0,
      com[1] - (feet[0][1] + feet[1][1]) / 2.0,
      0.0,
    ]
    truth.push(@balance.matvec(@balance.transpose(rotation), error))
    let observation = runtime.observation(Array::make(nu, 0.0))
    predicted.push(geometry.from_observation(observation))
    predicted32.push(@float32.from_observation(geometry, observation))
  }
  let result = errors(predicted, truth)
  guard number(result, "maximum_error") <= 1.0e-10 else {
    fail("observation-derived random-pose geometry differs from native model")
  }
  let result32 = errors(predicted32, truth)
  guard number(result32, "maximum_error") <= 2.0e-6 else {
    fail(
      "float32 observation-derived random-pose geometry differs from native model",
    )
  }
  [
    { "dtype": "float64", "errors": result },
    { "dtype": "float32", "errors": result32 },
  ]
}

///|
struct ReferenceEpisode {
  errors : Array[Array[Double]]
  full_velocity : Array[Array[Double]]
  short_velocity : Array[Array[Double]]
  rotations : Array[Array[Double]]
  full_actions : Array[Array[Double]]
  short_actions : Array[Array[Double]]
}

///|
fn reference_episode(
  runtime : @native_physics.Runtime,
  episode : @native_physics.Episode,
  parameters : @balance.FeedbackParameters,
  dt : Double,
) -> ReferenceEpisode raise {
  let full = @balance_native.NativeBalanceTeacher::new(runtime, parameters, dt)
  let short = @intervention.WindowTeacher::new(runtime, parameters, 10, dt)
  let result : ReferenceEpisode = {
    errors: [],
    full_velocity: [],
    short_velocity: [],
    rotations: [],
    full_actions: [],
    short_actions: [],
  }
  runtime.set_friction(episode.context[0])
  for step in episode.steps {
    runtime.set_state(step.state)
    result.full_actions.push(full.predict(step.observation, step.goal))
    result.short_actions.push(short.predict(step.observation, step.goal))
    let (rotation, _, _) = full.measurements()
    let (last, velocity) = full.memory()
    let inverse = @balance.transpose(rotation)
    result.errors.push(@balance.matvec(inverse, last.unwrap()))
    result.full_velocity.push(@balance.matvec(inverse, velocity))
    result.short_velocity.push(@balance.matvec(inverse, short.velocity()))
    result.rotations.push(rotation)
  }
  result
}

///|
pub fn verify_log(
  runtime : @native_physics.Runtime,
  geometry : @balance.Kinematics,
  parameters : @balance.FeedbackParameters,
  config : Json,
  records : Array[Json],
  dt : Double,
) -> Array[Json] raise {
  let modes : Array[String] = @json.from_json(field(config, "source_modes"))
  let methods : Array[String] = @json.from_json(
    field(config, "transport_methods"),
  )
  let (lower, upper) = runtime.control_bounds()
  let indices = @balance.joint_groups(runtime.joint_names())["ankle"]
  let rows : Array[Json] = []
  for record in records {
    let mode : String = @json.from_json(field(record, "mode"))
    if !modes.contains(mode) {
      continue
    }
    let episodes : Array[@native_physics.Episode] = @json.from_json(
      field(field(record, "dataset"), "episodes"),
    )
    let trials : Array[Json] = @json.from_json(field(record, "trials"))
    guard trials.length() == episodes.length() else {
      fail("feature source episodes/trials differ")
    }
    for index, episode in episodes {
      guard field(trials[index], "episode_id") == episode.id.to_json() else {
        fail("feature source episode identity mismatch")
      }
      let observations = episode.steps.map(fn(s) { s.observation })
      let expected = reference_episode(runtime, episode, parameters, dt)
      let predicted = observations.map(fn(obs) {
        geometry.from_observation(obs)
      })
      let position_error = errors(predicted, expected.errors)
      guard number(position_error, "maximum_error") <= 1.0e-10 else {
        fail("recorded observation geometry differs from native truth")
      }
      let oracle = Array::makei(observations.length(), fn(i) {
        if i == 0 {
          @balance.identity()
        } else {
          @balance.matmul(
            @balance.transpose(expected.rotations[i]),
            expected.rotations[i - 1],
          )
        }
      })
      let oracle_rows : Array[Json] = []
      for
        (window, target) in [
          (Some(10), expected.short_velocity),
          (None, expected.full_velocity),
        ] {
        let check = errors(
          @balance.causal_velocity(predicted, oracle, dt, window),
          target,
        )
        guard number(check, "maximum_error") <= 1.0e-9 else {
          fail("oracle transported causal velocity differs from teacher EMA")
        }
        guard check is Object(check_fields) else {
          fail("oracle error object required")
        }
        check_fields["window"] = match window {
          Some(n) => n.to_json()
          None => "full"
        }
        oracle_rows.push(Json::object(check_fields))
      }
      let exact = Array::makei(observations.length(), fn(i) {
        let feature = expected.errors[i].copy()
        feature.append(expected.full_velocity[i])
        @balance.observation_ankle_feedback(
          parameters,
          geometry.nu,
          indices,
          lower,
          upper,
          observations[i],
          episode.steps[i].goal,
          feature,
        )
      })
      let action_check = errors(
        exact,
        expected.full_actions.map(fn(action) {
          indices.map(fn(i) { action[i] })
        }),
      )
      guard number(action_check, "maximum_error") <= 1.0e-10 else {
        fail("exact fixed ankle feedback differs from privileged teacher")
      }
      let estimates : Array[Json] = []
      for dtype in ["float64", "float32"] {
        for name in methods {
          let transport_method : @balance.TransportMethod = match name {
            "gravity_gyro" => GravityGyro
            "gyro" => Gyro
            "body_difference" => BodyDifference
            _ => fail("unknown feature frame transport")
          }
          for
            (window, target, actions) in [
              (Some(10), expected.short_velocity, expected.short_actions),
              (None, expected.full_velocity, expected.full_actions),
            ] {
            let features = if dtype == "float64" {
              @balance.sequence_features(
                geometry, observations, dt, window, transport_method,
              )
            } else {
              @float32.sequence_features(
                geometry, observations, dt, window, transport_method,
              )
            }
            let actual = Array::makei(observations.length(), fn(i) {
              @balance.observation_ankle_feedback(
                parameters,
                geometry.nu,
                indices,
                lower,
                upper,
                observations[i],
                episode.steps[i].goal,
                features[i],
              )
            })
            let velocity = features.map(fn(row) { [row[3], row[4], row[5]] })
            estimates.push({
              "dtype": dtype.to_json(),
              "method": name.to_json(),
              "window": match window {
                Some(n) => n.to_json()
                None => "full"
              },
              "velocity": errors(velocity, target),
              "ankle_action": errors(
                actual,
                actions.map(fn(row) { indices.map(fn(i) { row[i] }) }),
              ),
            })
          }
        }
      }
      rows.push({
        "parent_seed": field(record, "seed"),
        "source_mode": mode.to_json(),
        "episode_id": episode.id.to_json(),
        "case_id": episode.case_id.to_json(),
        "split": episode.split.to_json(),
        "scope": field(trials[index], "scope"),
        "points": observations.length().to_json(),
        "geometry": position_error,
        "oracle_transport": oracle_rows.to_json(),
        "exact_feedback": action_check,
        "estimates": estimates.to_json(),
      })
    }
  }
  rows
}
