///|
async fn run(report : String, shadow : Bool) -> Unit {
  let effort_shadow = @env.get_env_var("MOONROBO_E1_REPORTED_EFFORT_SHADOW")
    is Some("1")
  guard !effort_shadow || shadow else {
    fail("reported-effort hypothesis is shadow only")
  }
  let preparation_started = @env.now().reinterpret_as_int64()
  let (bundle, actor, clip, config) = load()
  let current_pose = current_pose_profile()
  let supported = supported_hold_profile()
  guard supported is None || (current_pose is Some(_) && !effort_shadow) else {
    fail(
      "supported actor requires the measured pose and position-only feedback",
    )
  }
  defer (actor.close() catch { _ => () })
  diagnose(
    "actor artifacts verified and NPU prepared in " +
    (@env.now().reinterpret_as_int64() - preparation_started).to_string() +
    " ms",
  )
  let mapping = @mapping.Mapping::new(bundle, config.joint_calibration, resolve=name => {
    guard config.joint_calibration.axes.search_by(a => a.sdk_joint == name)
      is Some(index) else {
      guard config.joint_calibration.fixed.search_by(a => a.sdk_joint == name)
        is Some(index) else {
        fail("unknown calibrated SDK name")
      }
      return config.joint_calibration.fixed[index].motor_id
    }
    config.joint_calibration.axes[index].motor_id
  })
  let imu = @mapping.Imu::new(config.imu_calibration)
  let encoder = bundle.smc_observation()
  let mut s = timed_status(10000, "initial actor status")
  let mut startup_discarded = 0
  let startup = @env.now().reinterpret_as_int64()
  while @env.now().reinterpret_as_int64() - s.packet.arrival_ns / 1000000L > 40L {
    guard @env.now().reinterpret_as_int64() - startup < 10000L else {
      fail("no fresh actor startup telemetry")
    }
    startup_discarded += 1
    s = timed_status(40, "draining startup telemetry")
  }
  if s.packet.starts_on_standing_spike() {
    let recovery = timed_status(6, "startup ankle recovery")
    guard recovery.packet.confirms_standing_start(s.packet) else {
      fail("actor ankle startup did not recover")
    }
    s = recovery
  }
  let mut detector = @ankle.Detector::new(s.packet, confirm_isolated=true)
  diagnose(
    "fresh first actor packet " +
    s.packet.seq.to_string() +
    "; discarded " +
    startup_discarded.to_string() +
    " startup packets",
  )
  let opening_ms = s.packet.arrival_ns / 1000000L
  let mut baseline : Array[@low.MotorCommand] = []
  let mut effort_commands : Array[@low.MotorCommand] = []
  let mut effort_seed : Json = Json::null()
  let mut adapter : @adapter.Adapter? = None
  let mut hold_feedback : @elbow.SupportedHoldFeedback? = None
  let mut hold_seed : Status? = None
  let mut hold_meta : Json = Json::null()
  let mut previous = Array::make(29, 0.0)
  let history : Array[Array[Double]] = []
  let execution : @skills.Execution = {
    request_id: "actor-elbows",
    sequence: 0L,
    skill_id: "actor-elbows",
    reference_id: clip.reference_id(),
    parameters: {},
    state: Running,
    accepted_at_ms: 0L,
    deadline_ms: 0L,
    detail: "experimental constrained live actor",
  }
  let identity = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]
  let mut alignment = [1.0, 0.0]
  let mut started = 0L
  let mut last_inference = 0L
  let mut scheduled_inference = 0L
  let mut maximum_lateness = 0L
  let mut last_input_receipt = 0L
  let mut last_heartbeat = 0L
  let mut inference_sequence = -1
  let mut sequence = 0
  let mut packets = 0
  let mut policy_updates = 0
  let mut maximum_inference_ms = 0L
  let mut maximum_input_to_output_age_ms = 0L
  let mut returned_at : Int64? = None
  let mut finish_after_heartbeat = false
  let reference_duration = clip
    .duration_ms()
    .min(config.maximum_policy_ms.to_int64())
  let duration = reference_duration + config.approach_ms.to_int64()
  let mut commands : Array[@low.MotorCommand] = []
  let mut inference : Json = Json::null()
  for ;; {
    packets += 1
    let now = @env.now().reinterpret_as_int64()
    guard now >= s.packet.arrival_ns / 1000000L &&
      now - s.packet.arrival_ns / 1000000L <= 40L else {
      fail("stale actor telemetry")
    }
    match detector.observe(s.packet) {
      Stop(reason, slot) => fail(reason + " slot " + slot.to_string())
      Wait => ()
      Use => {
        let effort_available = s.reported_tau is Some(tau) &&
          @elbow.reported_leg_effort_shadow_available(tau[:])
        if adapter is None && effort_shadow {
          guard now - opening_ms <= 10000L else {
            fail("no complete shadow leg effort seed")
          }
        }
        if adapter is None &&
          now - opening_ms >= 1000L &&
          (!effort_shadow || effort_available) {
          baseline = hold_from(s)
          commands = baseline.copy()
          adapter = Some(@adapter.Adapter::new(config.adapter, baseline[:]))
          if supported is Some(profile) {
            hold_feedback = Some(
              @elbow.SupportedHoldFeedback::new(profile, sample_from(s)),
            )
            hold_seed = Some(s)
          }
          if effort_shadow {
            let tau = s.reported_tau.unwrap()
            effort_commands = sample_from(s).reported_leg_effort_shadow_candidate(
              tau[:],
              shadow~,
            )
            effort_seed = {
              "format": "moonrobo.e1-reported-leg-effort-shadow.v1",
              "power_qualified": false,
              "seed_packet_sequence": Json(s.packet.seq),
              "seed_arrival_ns": s.packet.arrival_ns.to_string(),
              "reported_torque": Json(tau),
              "seed_position": Json(s.packet.q),
              "seed_velocity": Json(s.packet.qd),
            }
          }
          previous = mapping.actions_for_commands(commands[:])
          let attitude = imu.decode(
            s.orientation[:],
            s.angular_velocity[:],
            identity[:],
          )
          alignment = @reference.heading_alignment(
            attitude.body_to_world()[:],
            clip.frame(execution, 0).body_to_world[:],
          )
          detector = assessed_hold(detector, s.packet, shadow, current_pose)
          if supported is Some(_) {
            detector = detector.begin_hold(
              moving_right_elbow=true,
              leg_tolerance_rad=5.0 * @ankle.RAD,
              stationary_tolerance_rad=5.0 * @ankle.RAD,
            )
          }
          started = now
          scheduled_inference = now
          diagnose("actor baseline established")
        }
        if adapter is Some(control) {
          guard now - started <= config.maximum_total_ms.to_int64() else {
            fail("actor session time limit")
          }
          for slot in [3, 14] {
            guard s.packet.q[slot] >=
              config.adapter.lower_rad[if slot == 3 { 0 } else { 1 }] &&
              s.packet.q[slot] <=
              config.adapter.upper_rad[if slot == 3 { 0 } else { 1 }] &&
              (
                shadow ||
                (s.packet.q[slot] - commands[slot].position).abs() <=
                config.following_tolerance_rad
              ) else {
              fail("actor elbow feedback range or following limit")
            }
          }
          if inference_sequence < 0 || now >= scheduled_inference {
            let lateness = now - scheduled_inference
            guard lateness >= 0L && lateness <= 10L else {
              fail("actor inference scheduling deadline missed")
            }
            maximum_lateness = maximum_lateness.max(lateness)
            let elapsed = scheduled_inference - started
            let policy_elapsed = (elapsed - 1000L).max(0L)
            let phase = if elapsed < 1000L {
              "baseline"
            } else if policy_elapsed <= duration {
              "policy"
            } else {
              "return"
            }
            let reference_step = ((policy_elapsed -
            config.approach_ms.to_int64())
            .max(0L)
            .min(reference_duration) /
            20L).to_int()
            let frame = clip.frame(execution, reference_step)
            let rotation = @reference.align_heading(
              alignment[:],
              frame.body_to_world[:],
            )
            let (q, qd) = mapping.joint_values(
              s.motor_ids[:],
              s.packet.q[:],
              s.packet.qd[:],
              s.packet.error[:],
            )
            let attitude = imu.decode(
              s.orientation[:],
              s.angular_velocity[:],
              rotation[:],
            )
            let input_previous = previous.copy()
            let observation = encoder.encode(
              q[:],
              qd[:],
              input_previous[:],
              attitude.body_gyro()[:],
              attitude.gravity()[:],
              attitude.reference_orientation()[:],
            )
            if history.is_empty() {
              for _ in 0..<bundle.history_frames() {
                history.push(observation.copy())
              }
            } else {
              ignore(history.remove(0))
              history.push(observation)
            }
            let before = @env.now().reinterpret_as_int64()
            let raw = actor.forward_embedded(history, frame.goals)
            let inferred = @env.now().reinterpret_as_int64()
            guard inferred - s.packet.arrival_ns / 1000000L <= 40L else {
              fail("actor inference result expired")
            }
            let nominal = mapping.commands(raw[:])
            let step = control.next(nominal[:], now, policy_elapsed, phase)
            commands = step.commands
            if hold_feedback is Some(feedback) &&
              supported is Some(profile) &&
              hold_seed is Some(seed) {
              let held = feedback.next(sample_from(s), now)
              for slot in 0..<23 {
                if @elbow.leg_slot(slot) {
                  commands[slot] = {
                    ..commands[slot],
                    torque: held[slot].torque,
                  }
                }
              }
              hold_meta = hold_metadata(profile, seed, s, now)
            }
            if effort_shadow {
              for slot in 0..<23 {
                if @elbow.leg_slot(slot) {
                  commands[slot] = {
                    ..commands[slot],
                    torque: effort_commands[slot].torque,
                  }
                }
              }
            }
            previous = mapping.actions_for_commands(commands[:])
            maximum_inference_ms = maximum_inference_ms.max(inferred - before)
            maximum_input_to_output_age_ms = maximum_input_to_output_age_ms.max(
              inferred - s.packet.arrival_ns / 1000000L,
            )
            inference_sequence += 1
            if phase == "policy" {
              policy_updates += 1
            }
            inference = {
              "model_id": config.model_id,
              "inference_sequence": Json(inference_sequence),
              "inferred_at_ms": inferred.to_string(),
              "adapter_tick_ms": now.to_string(),
              "scheduled_tick_ms": scheduled_inference.to_string(),
              "input_receipt_ms": (s.packet.arrival_ns / 1000000L).to_string(),
              "input_packet_sequence": Json(s.packet.seq),
              "phase": Json(phase),
              "policy_elapsed_ms": policy_elapsed.to_string(),
              "reference_step": Json(reference_step),
              "reference": clip.reference_id(),
              "inference_ms": Json(inferred - before),
              "observation": Json(history[history.length() - 1]),
              "goals": Json(frame.goals),
              "raw_actions": Json(raw),
              "previous_applied_actions": Json(input_previous),
              "applied_actions": Json(previous),
              "raw_elbow_rad": Json(step.raw_elbow_rad),
              "requested_elbow_rad": Json(step.requested_elbow_rad),
              "bounded_elbow_rad": Json(step.bounded_elbow_rad),
              "rate_limited": Json(step.rate_limited),
              "authority": step.authority,
            }
            last_inference = now
            scheduled_inference += 20L
            last_input_receipt = s.packet.arrival_ns / 1000000L
            if phase == "return" && control.returned() {
              if returned_at is None {
                returned_at = Some(now)
              }
              if now - returned_at.unwrap() >= 500L {
                finish_after_heartbeat = true
              }
            }
          }
          if finish_after_heartbeat || now - last_heartbeat >= 10L {
            guard @env.now().reinterpret_as_int64() - last_inference <= 40L &&
              @env.now().reinterpret_as_int64() - last_input_receipt <= 40L else {
              fail("actor inference heartbeat or input expired")
            }
            emit({
              "kind": "target",
              "stage": "actor-elbows",
              "shadow": Json(shadow),
              "reported_leg_effort_shadow": effort_seed,
              "actor_position_hold": hold_meta,
              "current_pose_commissioning": current_pose
              .map(p => p.to_json())
              .unwrap_or(Json::null()),
              "feedback_assessment": if current_pose is Some(_) {
                "measured current-pose commissioning; fixed non-elbow targets; relative guard"
              } else if shadow {
                "relative stationary shadow; nominal SDK ranges diagnostic"
              } else {
                "powered SDK feedback range validation"
              },
              "nominal_sdk_leg_range_discrepancies": Json(
                nominal_leg_range_discrepancies(s.packet),
              ),
              "profile": "suspended",
              "receipt_ms": @env.now().to_string(),
              "telemetry_receipt_ms": (s.packet.arrival_ns / 1000000L).to_string(),
              "telemetry_source_ns": s.packet.source_ns.to_string(),
              "motor_ids": Json(s.motor_ids),
              "packet_sequence": Json(s.packet.seq),
              "sequence": Json(sequence),
              "action": 11,
              "axes": [0, 0],
              "inference": inference,
              "motors": Json(
                commands.mapi((i, m) => {
                  "motor_id": Json(i),
                  "pos": Json(m.position),
                  "vel": Json(m.velocity),
                  "tau": Json(m.torque),
                  "kp": Json(m.kp),
                  "kd": Json(m.kd),
                }),
              ),
            })
            sequence += 1
            last_heartbeat = now
          }
          if finish_after_heartbeat {
            break
          }
        }
      }
    }
    let timeout = match detector.pending {
      Some(p) =>
        ((p.arrival_ns + @ankle.CONFIRM_NS + 999999L) / 1000000L - now)
        .to_int()
        .max(1)
      None => 40
    }
    s = timed_status(
      timeout,
      if detector.pending is Some(_) {
        "baseline ankle confirmation"
      } else {
        "actor packet stream"
      },
    )
  }
  let control_elapsed = @env.now().reinterpret_as_int64() - started
  emit({ "kind": "stop", "reason": "stage complete" })
  let close_started = @env.now().reinterpret_as_int64()
  actor.close()
  let close_elapsed = @env.now().reinterpret_as_int64() - close_started
  let result : Json = {
    "stage": "actor-elbows",
    "software_stage_completed": true,
    "shadow": Json(shadow),
    "reported_leg_effort_shadow": effort_seed,
    "actor_position_hold_profile": supported
    .map(p => p.to_json())
    .unwrap_or(Json::null()),
    "model_id": config.model_id,
    "backend": "LunaKine Ascend FP32",
    "policy_updates": Json(policy_updates),
    "inference_updates": Json(inference_sequence + 1),
    "target_heartbeats": Json(sequence),
    "packets": Json(packets),
    "startup_discarded_before_baseline": Json(startup_discarded),
    "maximum_inference_ms": maximum_inference_ms.to_string(),
    "maximum_lateness_ms": maximum_lateness.to_string(),
    "maximum_kernel_arrival_to_inference_ms": maximum_input_to_output_age_ms.to_string(),
    "active_ms": control_elapsed.to_string(),
    "actor_close_ms": close_elapsed.to_string(),
    "max_fixed_target_change": 0,
    "moving_slots": [3, 14],
    "target_positions_returned_exactly": true,
    "physical_handback_verified": false,
    "current_pose_commissioning": current_pose
    .map(p => p.to_json())
    .unwrap_or(Json::null()),
    "feedback_assessment": if current_pose is Some(_) {
      "measured current-pose commissioning; fixed non-elbow targets; relative guard"
    } else if shadow {
      "relative stationary shadow; nominal SDK ranges diagnostic"
    } else {
      "powered SDK feedback range validation"
    },
    "nominal_sdk_leg_range_discrepancies_at_hold": Json(
      if baseline.is_empty() {
        []
      } else {
        Array::makei(24, i => i).filter(slot => {
          @elbow.leg_slot(slot) &&
          !@elbow.leg_position_in_range(slot, baseline[slot].position)
        })
      },
    ),
    "calibration_scope": config.scope,
    "following_check": if shadow {
      "not applicable to read-only shadow; no motor targets executed"
    } else {
      "measured feedback versus last applied target"
    },
  }
  @fs.write_file(report, result.stringify(indent=2), create_mode=CreateNew)
}

///|
async fn main {
  let (report, shadow) = match @env.args()[1:] {
    ["actor-elbows", report] => (report, false)
    ["actor-elbows", report, "--shadow"] => (report, true)
    _ => fail("usage: actor-elbows NEW_REPORT [--shadow]")
  }
  guard !@fs.exists(report) else { fail("actor report already exists") }
  let mut reason = "actor controller interrupted"
  errdefer emit({ "kind": "stop", "reason": Json(reason) })
  let result = try run(report, shadow) catch {
    error => Err(error)
  } noraise {
    _ => Ok(())
  }
  match result {
    Ok(_) => ()
    Err(error) => {
      reason = error.to_string()
      raise error
    }
  }
}
