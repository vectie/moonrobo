///|
/// The 5-degree trial uses the vendor standing example in SDK slot order.
/// The 90-degree regression retains its original synthetic fixture.
fn shadow_hold(
  clip : @elbow.Clip,
  initial : @elbow.Sample,
) -> Array[@low.MotorCommand] raise {
  clip.validate()
  if clip.offset_degrees[375] == -5.0 {
    return initial.stand_candidate()
  }
  guard initial.motors.length() == 24 else { fail("24 status motors required") }
  Array::makei(24, slot => {
    let tag = slot.to_double() + 1.0
    {
      position: if slot == 23 {
        0.375
      } else {
        initial.motors[slot].position
      },
      velocity: 0.0,
      torque: tag / 1000.0,
      kp: tag,
      kd: tag / 100.0,
    }
  })
}

///|
async fn read_reference(arg : String) -> @elbow.Clip {
  if arg == "--gentle" {
    return @elbow.Clip::gentle()
  }
  @json.from_json(@fs.read_file(arg).json())
}

///|
enum Inputs {
  Recorded
  IdealTracking
  RecordedWithTrackingElbow
}

///|
async fn replay(
  clip : @elbow.Clip,
  samples : Array[@elbow.Sample],
  inputs : Inputs,
) -> Json {
  let hold = shadow_hold(clip, samples[0])
  let path = @elbow.Path::new(clip, hold[:])
  let rad = 0.017453292519943295
  let slot = @elbow.ELBOW_SLOT
  let positions : Array[Double] = []
  let mut leg_delta = 0.0
  let mut stop_reason : String? = None
  let start_ms = @env.now().reinterpret_as_int64()
  let mut last_tick_ms = start_ms
  let mut max_late_ms = 0L
  for step, recorded in samples {
    let mut sample = match inputs {
      Recorded => recorded
      IdealTracking | RecordedWithTrackingElbow => {
        let motors = match inputs {
          IdealTracking => samples[0].motors.copy()
          _ => recorded.motors.copy()
        }
        let last = if step == 0 { 0 } else { step - 1 }
        motors[slot] = {
          ..motors[slot],
          position: hold[slot].position + clip.offset_degrees[last] * rad,
        }
        { ..recorded, motors, }
      }
    }
    let now = if inputs is IdealTracking {
      let due = start_ms + step.to_int64() * @elbow.DT_MS.to_int64()
      let remaining = due - @env.now().reinterpret_as_int64()
      if remaining > 0L {
        @async.sleep(remaining.to_int())
      }
      last_tick_ms = @env.now().reinterpret_as_int64()
      max_late_ms = max_late_ms.max(last_tick_ms - due)
      // Synthetic status becomes available at its nominal tick in this
      // paced test. Recorded trials instead use their original receipt times.
      sample = { ..sample, receipt_ms: due, }
      last_tick_ms
    } else {
      sample.receipt_ms
    }
    let frame = path.next(sample, now) catch {
      err => {
        stop_reason = Some(err.to_string())
        break
      }
    }
    guard frame.length() == 24 else { fail("incomplete candidate frame") }
    for i, command in frame {
      let base = hold[i]
      guard (i == slot || command.position == base.position) &&
        command.velocity == base.velocity &&
        command.torque == base.torque &&
        command.kp == base.kp &&
        command.kd == base.kd else {
        fail("isolation violation at SDK slot " + i.to_string())
      }
      if @elbow.leg_slot(i) {
        leg_delta = leg_delta.max((command.position - base.position).abs())
      }
    }
    let expected = hold[slot].position + clip.offset_degrees[step] * rad
    guard (frame[slot].position - expected).abs() < 1.0e-12 else {
      fail("reference mismatch")
    }
    positions.push(frame[slot].position / rad)
  }
  // All runs are one-shot; a failure or completion must consume the context.
  let latched = try {
    ignore(
      path.next(
        samples[samples.length() - 1],
        samples[samples.length() - 1].receipt_ms,
      ),
    )
    false
  } catch {
    _ => true
  }
  guard latched else { fail("candidate emitted after a stop") }
  if inputs is IdealTracking {
    guard positions.length() == @elbow.FRAMES &&
      stop_reason is None &&
      positions[0] == positions[@elbow.FRAMES - 1] else {
      fail("stationary-legs, following-elbow fixture did not complete")
    }
  }
  let stop : Json = match stop_reason {
    None => Json::null()
    Some(reason) =>
      {
        "frame": Json(positions.length()),
        "reason": reason,
        "scheduled_ms": Json(positions.length() * @elbow.DT_MS),
      }
  }
  {
    "candidate_frames": Json(positions.length()),
    "paced_fixture_timing": if inputs is IdealTracking {
      {
        "elapsed_ms": Json((last_tick_ms - start_ms).to_int()),
        "maximum_late_ms": Json(max_late_ms.to_int()),
      }
    } else {
      Json::null()
    },
    "first_rejection": stop,
    "elbow_position_deg": Json(positions),
    "max_leg_target_change_rad": leg_delta,
    "other_motor_fields_unchanged": true,
    "latched_at_end": true,
  }
}

///|
async fn main {
  if @env.args()[1:] is ["--check-teach", clip_file, recording, start, output] {
    check_teach_recording(
      clip_file,
      recording,
      @string.parse_int(start),
      output,
    )
    return
  }
  if @env.args()[1:] is ["--packet-stream", clip_file, output] {
    run_packet_stream(clip_file, output)
    return
  }
  guard @env.args()[1:] is [clip_file, status_file, output] else {
    fail(
      "usage: e1_elbow_shadow REFERENCE_JSON RECORDED_STATUS_JSON NEW_REPORT | --packet-stream REFERENCE_JSON NEW_REPORT | --check-teach REFERENCE_JSON STATUS_NDJSON START_SEQUENCE NEW_REPORT",
    )
  }
  let clip = read_reference(clip_file)
  clip.validate()
  let samples : Array[@elbow.Sample] = @json.from_json(
    @fs.read_file(status_file).json(),
  )
  guard samples.length() == @elbow.FRAMES else {
    fail("751 recorded samples required")
  }
  // Validate the complete recording before indexing or building any counterfactuals.
  for sample in samples {
    guard sample.motors.length() == 24 else {
      fail("missing motor slot in recording")
    }
  }
  let baseline = samples[0]
  let mut max_leg_deg = 0.0
  let mut worst_slot = 0
  let mut worst_frame = 0
  let mut excursions = 0
  for i, s in samples {
    let mut drift = 0.0
    for slot, motor in s.motors {
      if @elbow.leg_slot(slot) {
        let delta = (motor.position - baseline.motors[slot].position).abs() *
          57.29577951308232
        drift = drift.max(delta)
        if delta > max_leg_deg {
          max_leg_deg = delta
          worst_slot = slot
          worst_frame = i
        }
      }
    }
    if drift > 1.0 {
      excursions += 1
    }
  }
  let report : Json = {
    "format": "moonrobo.e1-elbow-shadow.v1",
    "reference_joint": clip.joint,
    "sdk_slot": Json(@elbow.ELBOW_SLOT),
    "sdk_joint": "arm_l4_joint",
    "scope": "offline replay",
    "reference_peak_deg": clip.offset_degrees[375],
    "tracking_tolerance_deg": clip.tracking_tolerance_deg(),
    "hold_source": if clip.offset_degrees[375] == -5.0 {
      "vendor standing example at initial pose"
    } else {
      "synthetic fixture"
    },
    "published": false,
    "unit_calibrated": false,
    "physical_hold_verified": false,
    "duration_ms": 15000,
    "step_ms": Json(@elbow.DT_MS),
    "stationary_legs_ideal_elbow": replay(clip, samples, IdealTracking),
    "recorded_status": replay(clip, samples, Recorded),
    "recorded_other_joints_ideal_elbow": replay(
      clip,
      samples,
      RecordedWithTrackingElbow,
    ),
    "measured_leg_drift": {
      "max_deg": max_leg_deg,
      "sdk_slot": Json(worst_slot),
      "frame": Json(worst_frame),
      "frames_above_one_degree": Json(excursions),
    },
  }
  @fs.write_file(output, report.stringify(indent=2), create_mode=CreateNew)
}
