///|
priv struct ModelLimit {
  joint : String
  lower : Double
  upper : Double
} derive(FromJson)

///|
priv struct Configuration {
  format : String
  joint_calibration : @mapping.Calibration
  imu_calibration : @mapping.ImuCalibration
  reference_body_to_world : Array[Double]
  model_joint_limits : Array[ModelLimit]
  duration_ms : Int32
  maximum_sensor_age_ms : Int32
  calibration_scope : String
} derive(FromJson)

///|
// This is a stationary diagnostic reference, not an evaluated motion skill.
// The 73-value preview frame is root XYZ, row-interleaved rotation 6D,
// root linear/angular velocity, 29 joint positions and 29 velocities.
fn hold_preview(
  q : ArrayView[Double],
  rotation : ArrayView[Double],
) -> Array[Double] {
  let frame = [0.0, 0.0, 0.0]
  // Same projected-heading convention as MotionLibrary::goal (atlas=false).
  let vertical = rotation[0] * rotation[0] + rotation[3] * rotation[3] < 1.0e-12
  let x = if vertical { rotation[4] } else { rotation[0] }
  let y = if vertical { -rotation[1] } else { rotation[3] }
  let norm = (x * x + y * y).sqrt().max(1.0e-12)
  let (c, s) = (x / norm, y / norm)
  frame.append([
    c * rotation[0] + s * rotation[3],
    c * rotation[1] + s * rotation[4],
    -s * rotation[0] + c * rotation[3],
    -s * rotation[1] + c * rotation[4],
    rotation[6],
    rotation[7],
  ])
  frame.append(Array::make(6, 0.0))
  for i in 0..<29 {
    frame.push(if i < q.length() { q[i] } else { 0.0 })
  }
  frame.append(Array::make(29, 0.0))
  let goals = []
  for _ in 0..<10 {
    goals.append(frame)
  }
  goals
}

///|
fn validate_configuration(
  bundle : @actor.Bundle,
  configuration : Configuration,
) -> Unit raise {
  guard configuration.format == "moonrobo.e1-live-actor-shadow.v1" &&
    configuration.duration_ms > 0 &&
    configuration.maximum_sensor_age_ms >= 0 &&
    configuration.calibration_scope != "" &&
    bundle.joints().length() == 23 &&
    bundle.history_frames() == 10 &&
    bundle.observation_width() == 99 &&
    bundle.goal_width() == 730 else {
    fail("expected the declared 23-joint/99-feature/730-preview actor contract")
  }
  guard configuration.reference_body_to_world.length() == 9 &&
    configuration.model_joint_limits.length() == 23 else {
    fail("reference orientation or model limits are incomplete")
  }
  for i, limit in configuration.model_joint_limits {
    guard limit.joint == bundle.joints()[i] &&
      limit.lower < limit.upper &&
      limit.lower - limit.lower == 0.0 &&
      limit.upper - limit.upper == 0.0 else {
      fail("model limit order or finite range differs from the actor")
    }
  }
}

///|
async fn run_shadow(
  bundle : @actor.Bundle,
  actor : @actor.Actor,
  controller : @low.Controller,
  configuration : Configuration,
  output : String,
  reference~ : @reference.Clip?,
) -> Unit {
  let mapping = @mapping.Mapping::new(bundle, configuration.joint_calibration, resolve=name => {
    controller.joint_index(name)
  })
  let imu = @mapping.Imu::new(configuration.imu_calibration)
  let observer = @mapping.Observer::new(mapping, imu)
  let sample = @low.Sample::new()
  // Subscription startup is separate from the measured run.
  @async.sleep(100)
  controller.capture_into(sample)
  let (baseline, _) = mapping.joint_state(sample)
  let initial_attitude = imu.decode(
    sample.orientation()[:],
    sample.angular_velocity()[:],
    configuration.reference_body_to_world[:],
  )
  let reference_rotation = initial_attitude.body_to_world()[:].to_owned()
  let stationary_goals = hold_preview(baseline[:], reference_rotation[:])
  let execution : @skills.Execution = {
    request_id: "receive-only-reference-diagnostic",
    sequence: 0L,
    skill_id: "shadow",
    reference_id: reference.map(c => c.reference_id()).unwrap_or("stationary"),
    parameters: {},
    state: Running,
    accepted_at_ms: 0L,
    deadline_ms: 0L,
    detail: "reference sampling only; no control authority",
  }
  let alignment = match reference {
    Some(clip) =>
      heading_alignment(
        reference_rotation[:],
        clip.frame(execution, 0).body_to_world[:],
      )
    None => [1.0, 0.0]
  }
  let initial_goals = match reference {
    Some(clip) => clip.frame(execution, 0).goals
    None => stationary_goals
  }
  let history : Array[Array[Double]] = []
  let mut previous = Array::make(29, 0.0)
  let minimum = Array::make(23, 0.0)
  let maximum = Array::make(23, 0.0)
  let first_targets : Array[Double] = []
  let limit_violations = Array::make(23, 0)
  let started = @env.now().reinterpret_as_int64()
  let duration = match reference {
    Some(clip) => clip.duration_ms().min(configuration.duration_ms.to_int64())
    None => configuration.duration_ms.to_int64()
  }
  let end = started + duration
  let mut scheduled = started
  let mut frames = 0
  let mut missed_periods = 0L
  let mut maximum_age = 0L
  let mut maximum_inference = 0L
  let mut maximum_lateness = 0L
  while @env.now().reinterpret_as_int64() < end {
    let before_wait = @env.now().reinterpret_as_int64()
    if before_wait < scheduled {
      @async.sleep((scheduled - before_wait).to_int())
    }
    let captured = @env.now().reinterpret_as_int64()
    if captured >= end {
      break
    }
    maximum_lateness = maximum_lateness.max(captured - scheduled)
    controller.capture_into(sample)
    let age = sample.age_ms()
    guard age >= 0L && age <= configuration.maximum_sensor_age_ms.to_int64() else {
      fail("live observation exceeded the configured callback-age budget")
    }
    let (q, qd) = mapping.joint_state(sample)
    let reference_step = ((captured - started) / 20L).to_int()
    let (goals, current_reference_rotation) = match reference {
      Some(clip) => {
        let frame = clip.frame(execution, reference_step)
        (frame.goals, align_heading(alignment[:], frame.body_to_world[:]))
      }
      None => (stationary_goals, reference_rotation)
    }
    let observation = observer.observation(
      sample,
      previous[:],
      current_reference_rotation[:],
    )
    if history.is_empty() {
      for _ in 0..<bundle.history_frames() {
        history.push(observation.copy())
      }
    } else {
      ignore(history.remove(0))
      history.push(observation)
    }
    let inference_started = @env.now().reinterpret_as_int64()
    previous = actor.forward_embedded(history, goals)
    let inferred = @env.now().reinterpret_as_int64()
    let targets = bundle.nominal_setpoints(previous[:])
    let commands = mapping.commands(previous[:])
    assert_eq(commands.length(), 24)
    if frames == 0 {
      first_targets.append(targets)
    }
    for i, target in targets {
      minimum[i] = if frames == 0 { target } else { minimum[i].min(target) }
      maximum[i] = if frames == 0 { target } else { maximum[i].max(target) }
      let limit = configuration.model_joint_limits[i]
      if target < limit.lower || target > limit.upper {
        limit_violations[i] += 1
      }
    }
    maximum_age = maximum_age.max(age + inferred - captured)
    maximum_inference = maximum_inference.max(inferred - inference_started)
    let row : Json = {
      "format": "moonrobo.e1-live-actor-shadow-tick.v1",
      "published": false,
      "frame": Json(frames),
      "reference_step": Json(reference_step),
      "recorded_at_ms": Json(inferred),
      "callback_age_at_capture_ms": Json(age),
      "inference_ms": Json(inferred - inference_started),
      "motor_ids": Json(Array::makei(24, i => sample.joint(i).motor_id)),
      "measured_model_rad": Json(q),
      "measured_model_rad_s": Json(qd),
      "orientation": Json(sample.orientation()[:].to_owned()),
      "body_gyro_input": Json(sample.angular_velocity()[:].to_owned()),
      "gravity_feature": Json(observation[61:64].to_owned()),
      "reference_orientation_feature": Json(observation[93:99].to_owned()),
      "observation": Json(history[history.length() - 1]),
      "goals": Json(goals),
      "raw_actions": Json(previous),
      "nominal_model_rad": Json(targets),
      "sdk_target_rad": Json(commands.map(c => c.position)),
    }
    println(row.stringify())
    frames += 1
    scheduled += 20L
    let completed = @env.now().reinterpret_as_int64()
    if completed > scheduled {
      let missed = (completed - scheduled) / 20L + 1L
      missed_periods += missed
      scheduled += missed * 20L
    }
  }
  let joints = bundle.joints()[:].to_owned()
  let report : Json = {
    "format": "moonrobo.e1-live-actor-shadow-report.v1",
    "published": false,
    "profile": bundle.profile_id(),
    "backend": "LunaKine Ascend FP32",
    "reference": match reference {
      Some(clip) => Json(clip.reference_id())
      None =>
        Json("stationary current-pose diagnostic; not a qualified motion skill")
    },
    "calibration_scope": configuration.calibration_scope,
    "reference_body_to_world": Json(reference_rotation),
    "heading_alignment_cos_sin": Json(alignment),
    "preview_orientation6": Json(initial_goals[3:9].to_owned()),
    "goals": Json(initial_goals),
    "physical_control_qualified": false,
    "physical_actions": 23,
    "status_records_per_frame": 24,
    "reserved_slot": 23,
    "joints": Json(joints),
    "frames": Json(frames),
    "elapsed_ms": Json(@env.now().reinterpret_as_int64() - started),
    "missed_periods": Json(missed_periods),
    "maximum_lateness_ms": Json(maximum_lateness),
    "maximum_inference_ms": Json(maximum_inference),
    "maximum_callback_to_output_age_ms": Json(maximum_age),
    "baseline_model_rad": Json(baseline),
    "first_nominal_model_rad": Json(first_targets),
    "minimum_nominal_model_rad": Json(minimum),
    "maximum_nominal_model_rad": Json(maximum),
    "model_limit_violations_by_joint": Json(limit_violations),
  }
  @fs.write_file(output, report.stringify(indent=2), create_mode=CreateNew)
}
