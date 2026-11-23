///|
/// A forward gap may restart passive qualification; it never admits a command
/// or resets an armed guard. A fresh full second must follow the replacement.
fn supported_startup_rebaseline(
  armed : Bool,
  detector : @ankle.Detector,
  packet : @ankle.Packet,
) -> Bool {
  !armed &&
  detector.pending is None &&
  !packet.starts_on_standing_spike() &&
  detector.last is Some(before) &&
  packet.seq > before.seq &&
  packet.source_ns > before.source_ns &&
  packet.source_ns - before.source_ns <= 40000000L &&
  packet.arrival_ns > before.arrival_ns &&
  packet.arrival_ns - before.arrival_ns <= 40000000L
}

///|
/// One crane-supported, fixed-leg-target commissioning gesture. Shadow and
/// powered runs share the same calculation; only shadow omits elbow following.
async fn supported_elbow(report_file : String, shadow : Bool) -> Unit {
  guard @env.get_env_var("MOONROBO_E1_SUPPORTED_ELBOW_PROFILE") is Some(path) &&
    @env.get_env_var("MOONROBO_E1_CURRENT_POSE_PROFILE") is Some(pose_path) &&
    @env.get_env_var("MOONROBO_E1_POSITION_HOLD_TRIAL") is None &&
    @env.get_env_var("MOONROBO_E1_POSITION_HOLD_SHADOW") is None &&
    @env.get_env_var("MOONROBO_E1_REPORTED_EFFORT_SHADOW") != Some("1") else {
    fail("separate supported-elbow and measured-pose profiles required")
  }
  let profile : @elbow.SupportedElbowSettings = @json.from_json(
    @fs.read_file(path).json(),
  )
  profile.validate()
  let pose : @actor_elbows.CurrentPoseProfile = @json.from_json(
    @fs.read_file(pose_path).json(),
  )
  let (opening, _) = @async.with_timeout(10000, read_status)
  let mut first = if opening.starts_on_standing_spike() {
    let (next, _) = @async.with_timeout(6, read_status)
    guard next.confirms_standing_start(opening) else {
      fail("startup ankle did not recover")
    }
    next
  } else {
    opening
  }
  let mut detector = @ankle.Detector::new(first, confirm_isolated=true)
  let mut owner : @elbow.SupportedElbowTrial? = None
  let mut baseline = first
  let mut p = first
  let mut active_start = 0L
  let mut last_tick = 0L
  let mut count = 0
  let mut packets = 0
  let mut max_leg_feedback_deg = 0.0
  let mut final_frame = -1
  let startup_origin = first.arrival_ns / 1000000L
  let mut startup_restarts = 0
  for ;; {
    packets += 1
    let now = @env.now().reinterpret_as_int64()
    guard owner is Some(_) ||
      (now >= startup_origin && now - startup_origin <= 10000L) else {
      fail("supported elbow stationary baseline timeout")
    }
    guard now >= p.arrival_ns / 1000000L && now - p.arrival_ns / 1000000L <= 40L else {
      fail("stale telemetry")
    }
    if detector.pending is Some(suspect) {
      guard now * 1000000L <= suspect.arrival_ns + @ankle.CONFIRM_NS else {
        fail("ankle confirmation expired")
      }
    }
    match detector.observe(p) {
      Stop(reason, slot) =>
        if reason == "packet continuity lost" &&
          supported_startup_rebaseline(owner is Some(_), detector, p) {
          first = p
          detector = @ankle.Detector::new(p, confirm_isolated=true)
          guard detector.observe(p) is Use else {
            fail("invalid replacement startup sample")
          }
          startup_restarts += 1
        } else {
          fail(reason + " slot " + slot.to_string())
        }
      Wait => ()
      Use => {
        if owner is None && now - first.arrival_ns / 1000000L >= 1000L {
          guard (p.q[3] - first.q[3]).abs() <= @ankle.RAD else {
            fail("elbow moving during baseline")
          }
          pose.validate_baseline(p.q[:])
          baseline = p
          detector = detector.begin_hold(leg_tolerance_rad=3.0 * @ankle.RAD)
          owner = Some(
            @elbow.SupportedElbowTrial::new(profile, status_sample(p)),
          )
          active_start = now
        }
        if owner is Some(trial) {
          for slot in 0..<23 {
            if @elbow.leg_slot(slot) {
              max_leg_feedback_deg = max_leg_feedback_deg.max(
                (p.q[slot] - baseline.q[slot]).abs() / @ankle.RAD,
              )
            }
          }
          if now - active_start >= 18500L {
            break
          }
          if now - last_tick >= 10L {
            let motors = trial.next(status_sample(p), now, shadow~)
            final_frame = trial.reference_frame()
            emit_event({
              "kind": "target",
              "stage": "supported-elbow",
              "shadow": Json(shadow),
              "profile": "suspended",
              "current_pose_commissioning": pose.to_json(),
              "sequence": Json(count),
              "receipt_ms": now.to_string(),
              "telemetry_receipt_ms": (p.arrival_ns / 1000000L).to_string(),
              "telemetry_source_ns": p.source_ns.to_string(),
              "action": 11,
              "axes": [0, 0],
              "reference_frame": Json(final_frame),
              "supported_elbow_trial": {
                "profile": profile.to_json(),
                "power_qualified": false,
                "settings": profile.feedback.to_json(),
                "elapsed_ms": (now - active_start).to_string(),
                "seed_packet_sequence": Json(baseline.seq),
                "seed_arrival_ns": baseline.arrival_ns.to_string(),
                "seed_source_ns": baseline.source_ns.to_string(),
                "seed_position": Json(baseline.q),
                "input_packet_sequence": Json(p.seq),
                "input_arrival_ns": p.arrival_ns.to_string(),
                "input_source_ns": p.source_ns.to_string(),
                "input_position": Json(p.q),
                "input_velocity": Json(p.qd),
              },
              "motors": Json(
                motors.mapi((i, m) => {
                  "motor_id": Json(i),
                  "pos": Json(m.position),
                  "vel": Json(m.velocity),
                  "tau": Json(m.torque),
                  "kp": Json(m.kp),
                  "kd": Json(m.kd),
                }),
              ),
            })
            count += 1
            last_tick = now
          }
        }
      }
    }
    let timeout = if detector.pending is Some(suspect) {
      ((suspect.arrival_ns + @ankle.CONFIRM_NS + 999999L) / 1000000L - now)
      .to_int()
      .max(1)
    } else {
      40
    }
    let (next, _) = @async.with_timeout(timeout, read_status)
    p = next
  }
  guard final_frame == 750 else { fail("supported elbow reference incomplete") }
  emit_event({ "kind": "stop", "reason": "stage complete" })
  @fs.write_file(
    report_file,
    (
      {
        "stage": "supported-elbow",
        "shadow": Json(shadow),
        "software_stage_completed": true,
        "profile": profile.to_json(),
        "physical_handback_verified": false,
        "active_ms": Json(
          (@env.now().reinterpret_as_int64() - active_start).to_int(),
        ),
        "guarded_updates": Json(count),
        "startup_restarts": Json(startup_restarts),
        "packets": Json(packets),
        "final_reference_frame": Json(final_frame),
        "fixed_position_records": 23,
        "fixed_leg_position_records": 12,
        "moving_slots": [3],
        "max_leg_feedback_change_deg": max_leg_feedback_deg,
        "cleared_left_spikes": Json(detector.left_events),
        "cleared_right_only_spikes": Json(detector.right_only_events),
        "elbow_tracking": if shadow {
          "unexecuted; following check omitted"
        } else {
          "live one-degree following check"
        },
      } : Json).stringify(indent=2),
    create_mode=CreateNew,
  )
}
