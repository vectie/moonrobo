///|
/// Finite commissioning owner. Input is the fixed raw-packet decoder.
async fn emit_event(value : Json) -> Unit {
  let output : &@io.Writer = @stdio.stdout
  output.write(value.stringify() + "\n")
}

///|
async fn commission(
  stage : String,
  report_file : String,
  shadow~ : Bool = false,
) -> Unit {
  let effort_shadow = @env.get_env_var("MOONROBO_E1_REPORTED_EFFORT_SHADOW")
    is Some("1")
  guard !effort_shadow || (shadow && stage == "hold") else {
    fail("reported-effort hypothesis is hold shadow only")
  }
  let position_settings : @elbow.PositionHoldSettings? = match
    @env.get_env_var("MOONROBO_E1_POSITION_HOLD_SHADOW") {
    None => None
    Some(path) => {
      guard shadow && stage == "hold" && !effort_shadow else {
        fail(
          "position-feedback experiment requires hold shadow without reported effort",
        )
      }
      let settings : @elbow.PositionHoldSettings = @json.from_json(
        @fs.read_file(path).json(),
      )
      settings.validate()
      Some(settings)
    }
  }
  guard stage == "hold" ||
    stage == "elbow" ||
    stage == "elbow90" ||
    stage == "drums" ||
    stage == "raised-drums" ||
    stage == "typing-elbows" else {
    fail("hold, elbow or elbow90 stage required")
  }
  let dual = stage == "drums" ||
    stage == "raised-drums" ||
    stage == "typing-elbows"
  let raised = stage == "raised-drums" || stage == "typing-elbows"
  let current_pose : @actor_elbows.CurrentPoseProfile? = match
    @env.get_env_var("MOONROBO_E1_CURRENT_POSE_PROFILE") {
    None => None
    Some(path) => {
      guard stage == "hold" else {
        fail("measured-pose commissioning applies only to the hold stage")
      }
      Some(@json.from_json(@fs.read_file(path).json()))
    }
  }
  let (opening, opening_tau) = @async.with_timeout(10000, read_status)
  let (first, first_tau) = if opening.starts_on_standing_spike() {
    let recovery = @async.with_timeout(6, read_status)
    guard recovery.0.confirms_standing_start(opening) else {
      fail("startup ankle did not recover")
    }
    recovery
  } else {
    (opening, opening_tau)
  }
  let mut detector = @ankle.Detector::new(first, confirm_isolated=true)
  let mut hold : Array[@low.MotorCommand]? = None
  let mut path : @elbow.Path? = None
  let mut drums : @elbow.DrumPath? = None
  let mut active_start = 0L
  let mut motion_start = 0L
  let mut last_tick = 0L
  let mut frames = 0
  let mut ticks = 0
  let mut last_motion_tick = 0L
  let mut updates = 0
  let mut packets = 0
  let mut p = first
  let mut reported_tau = first_tau
  let mut effort_seed : Json = Json::null()
  let mut position_hold : PositionHoldExperiment? = None
  let mut position_meta : Json = Json::null()
  let mut final_start = 0L
  let mut max_leg_feedback_change_deg = 0.0
  let mut max_other_feedback_change_deg = 0.0
  let clip = if stage == "elbow90" {
    @elbow.Clip::slow_fold_return()
  } else {
    @elbow.Clip::gentle()
  }
  let frame_count = if raised {
    if stage == "typing-elbows" {
      @elbow.TYPING_ELBOW_FRAMES
    } else {
      @elbow.RAISED_DRUM_FRAMES
    }
  } else if dual {
    @elbow.DRUM_FRAMES
  } else {
    clip.offset_degrees.length()
  }
  let tolerance = if dual { 5.0 } else { clip.tracking_tolerance_deg() }
  clip.validate()
  let mut latest : Array[@low.MotorCommand] = []
  for ;; {
    packets += 1
    let now = @env.now().reinterpret_as_int64()
    guard now >= p.arrival_ns / 1000000L && now - p.arrival_ns / 1000000L <= 40L else {
      fail("stale telemetry")
    }
    if dual {
      for slot in [3, 14] {
        guard p.q[slot] >= -130.0 * @ankle.RAD && p.q[slot] <= 0.0 else {
          fail("raw drum elbow outside range at slot " + slot.to_string())
        }
      }
    }
    if detector.pending is Some(suspect) {
      guard now * 1000000L <= suspect.arrival_ns + @ankle.CONFIRM_NS else {
        fail("ankle confirmation expired")
      }
    }
    match detector.observe(p) {
      Stop(reason, slot) => fail(reason + " slot " + slot.to_string())
      Wait => ()
      Use => {
        let s = status_sample(p)
        if hold is None {
          if effort_shadow {
            guard now - first.arrival_ns / 1000000L <= 10000L else {
              fail("no complete shadow leg effort seed")
            }
          }
          guard (p.q[3] - first.q[3]).abs() <= @ankle.RAD else {
            fail("elbow moving during baseline")
          }
          if dual {
            guard (p.q[14] - first.q[14]).abs() <= @ankle.RAD else {
              fail("right elbow moving during baseline")
            }
          }
          let effort_available = reported_tau is Some(tau) &&
            @elbow.reported_leg_effort_shadow_available(tau[:])
          if now - first.arrival_ns / 1000000L >= 1000L &&
            (!effort_shadow || effort_available) {
            let current = if effort_shadow {
              let tau = reported_tau.unwrap()
              effort_seed = {
                "format": "moonrobo.e1-reported-leg-effort-shadow.v1",
                "power_qualified": false,
                "seed_packet_sequence": Json(p.seq),
                "seed_arrival_ns": p.arrival_ns.to_string(),
                "reported_torque": Json(tau),
                "seed_position": Json(p.q),
                "seed_velocity": Json(p.qd),
              }
              s.reported_leg_effort_shadow_candidate(tau[:], shadow~)
            } else {
              s.stand_candidate()
            }
            if current_pose is Some(profile) {
              profile.validate_baseline(p.q[:])
            }
            if dual {
              ignore(
                if raised {
                  if stage == "typing-elbows" {
                    @elbow.DrumPath::typing_pose(current[:])
                  } else {
                    @elbow.DrumPath::raised(current[:])
                  }
                } else {
                  @elbow.DrumPath::new(current[:])
                },
              )
            } else {
              ignore(@elbow.Path::new(clip, current[:], suspended=true))
            }
            hold = Some(current)
            latest = current
            if position_settings is Some(settings) {
              position_hold = Some(
                PositionHoldExperiment::new(settings, p, shadow~),
              )
            }
            active_start = now
            if current_pose is Some(_) {
              detector = detector.begin_hold()
            } else {
              detector = @ankle.Detector::new(
                p,
                confirm_isolated=true,
                suspended=true,
              )
              match detector.observe(p) {
                Use => ()
                Stop(reason, slot) => fail(reason + " slot " + slot.to_string())
                Wait =>
                  fail("provisional telemetry cannot establish a powered hold")
              }
            }
          }
        }
        if hold is Some(base) {
          for slot in 0..<23 {
            let delta = (p.q[slot] - base[slot].position).abs() / @ankle.RAD
            if @elbow.leg_slot(slot) {
              max_leg_feedback_change_deg = max_leg_feedback_change_deg.max(
                delta,
              )
            } else if slot != @elbow.ELBOW_SLOT && !(dual && slot == 14) {
              max_other_feedback_change_deg = max_other_feedback_change_deg.max(
                delta,
              )
            }
          }
          if path is None && drums is None {
            guard (p.q[3] - base[3].position).abs() <= tolerance * @ankle.RAD else {
              fail("elbow drift during hold")
            }
            if dual {
              guard (p.q[14] - base[14].position).abs() <=
                tolerance * @ankle.RAD else {
                fail("right elbow drift during hold")
              }
            }
            // A longer receive-only window exercises the experimental
            // integrator. Existing powered and other shadow stages keep their
            // one-second initial hold.
            let initial_hold_ms = if position_hold is Some(_) {
              15000L
            } else {
              1000L
            }
            if now - active_start >= initial_hold_ms {
              if stage == "hold" {
                break
              }
              if dual {
                drums = Some(
                  if raised {
                    if stage == "typing-elbows" {
                      @elbow.DrumPath::typing_pose(base[:])
                    } else {
                      @elbow.DrumPath::raised(base[:])
                    }
                  } else {
                    @elbow.DrumPath::new(base[:])
                  },
                )
              } else {
                path = Some(@elbow.Path::new(clip, base[:], suspended=true))
              }
              motion_start = now
            }
          }
          if (path is Some(_) || drums is Some(_)) &&
            frames < frame_count &&
            (if raised {
              now >= last_motion_tick + 20L
            } else {
              now >= motion_start + ticks.to_int64() * 20L
            }) {
            latest = if drums is Some(trajectory) {
              let feedback = if shadow {
                let motors = s.motors.copy()
                for slot in [3, 14] {
                  motors[slot] = {
                    ..motors[slot],
                    position: latest[slot].position,
                  }
                }
                { ..s, motors, }
              } else {
                s
              }
              trajectory.next(feedback, now)
            } else {
              path.unwrap().next(s, now)
            }
            ticks += 1
            last_motion_tick = now
            frames = if drums is Some(trajectory) {
              trajectory.frame_index()
            } else {
              frames + 1
            }
            if frames == frame_count {
              final_start = now
            }
          }
          if frames == frame_count {
            guard (p.q[3] - base[3].position).abs() <= tolerance * @ankle.RAD else {
              fail("elbow did not return")
            }
            if dual {
              guard (p.q[14] - base[14].position).abs() <=
                tolerance * @ankle.RAD else {
                fail("right elbow did not return")
              }
            }
            if now - final_start >= 500L {
              break
            }
          }
          // The independent sender repeats the latest validated target at 2 ms.
          // A 10 ms planner heartbeat avoids serializing identical 24-motor
          // frames on every status packet while retaining the 40 ms deadline.
          if now - last_tick >= 10L {
            if position_hold is Some(owner) {
              let (commands, metadata) = owner.next(p, now, shadow~)
              latest = commands
              position_meta = metadata
            }
            for i, m in latest {
              guard (
                  i == 3 || (dual && i == 14) || m.position == base[i].position
                ) &&
                m.velocity == base[i].velocity &&
                (
                  m.torque == base[i].torque ||
                  (position_hold is Some(_) && @elbow.leg_slot(i))
                ) &&
                m.kp == base[i].kp &&
                m.kd == base[i].kd else {
                fail("fixed target changed")
              }
            }
            emit_event({
              "kind": "target",
              "shadow": Json(shadow),
              "reported_leg_effort_shadow": effort_seed,
              "position_hold_shadow": position_meta,
              "current_pose_commissioning": current_pose
              .map(p => p.to_json())
              .unwrap_or(Json::null()),
              "stage": stage,
              "reference_frame": Json(frames - 1),
              "profile": "suspended",
              "receipt_ms": now.to_string(),
              "telemetry_receipt_ms": (p.arrival_ns / 1000000L).to_string(),
              "telemetry_source_ns": p.source_ns.to_string(),
              "sequence": Json(updates),
              "action": 11,
              "axes": [0.0, 0.0],
              "motors": Json(
                latest.mapi((i, m) => {
                  "motor_id": Json(i),
                  "pos": Json(m.position),
                  "vel": Json(m.velocity),
                  "tau": Json(m.torque),
                  "kp": Json(m.kp),
                  "kd": Json(m.kd),
                }),
              ),
            })
            updates += 1
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
    let (next, next_tau) = @async.with_timeout(timeout, read_status)
    p = next
    reported_tau = next_tau
  }
  emit_event({ "kind": "stop", "reason": "stage complete" })
  let report : Json = {
    "stage": stage,
    "profile": "suspended",
    "feedback": if shadow && dual {
      "live telemetry with explicitly simulated elbow tracking"
    } else {
      "live telemetry"
    },
    "software_stage_completed": true,
    "shadow": Json(shadow),
    "reported_leg_effort_shadow": effort_seed,
    "position_hold_shadow": position_meta,
    "fixed_position_records": if stage == "hold" {
      24
    } else if dual {
      22
    } else {
      23
    },
    "fixed_motor_records": if position_hold is Some(_) {
      12
    } else if stage == "hold" {
      24
    } else if dual {
      22
    } else {
      23
    },
    "adaptive_effort_slots": if position_hold is Some(_) {
      Json([5, 6, 7, 8, 9, 10, 16, 17, 18, 19, 20, 21])
    } else {
      Json(Array::make(0, 0))
    },
    "current_pose_commissioning": current_pose
    .map(p => p.to_json())
    .unwrap_or(Json::null()),
    "physical_handback_verified": false,
    "leg_acceptance": if position_hold is Some(_) {
      "fixed raw position targets; bounded position-error effort shadow; stationary/glitch guard"
    } else if current_pose is Some(_) {
      "explicit measured raw-pose hold; stationary/glitch guard; all targets fixed"
    } else {
      "feedback motion accepted within SDK leg ranges; command targets remain fixed"
    },
    "frames": Json(frames),
    "guarded_updates": Json(updates),
    "packets": Json(packets),
    "active_ms": Json(
      (@env.now().reinterpret_as_int64() - active_start).to_int(),
    ),
    "action": 11,
    "axes": [0.0, 0.0],
    "max_fixed_target_change": 0.0,
    "moving_slots": if stage == "hold" {
      Json(Array::make(0, 0))
    } else if dual {
      Json([3, 14])
    } else {
      Json([3])
    },
    "max_leg_feedback_change_deg": max_leg_feedback_change_deg,
    "max_other_feedback_change_deg": max_other_feedback_change_deg,
    "reference_wait_ticks": Json(ticks - frames),
    "cleared_left_spikes": Json(detector.left_events),
    "cleared_right_only_spikes": Json(detector.right_only_events),
    "baseline": "fresh pose after one second of valid stationary telemetry",
    "slot23": "position 0, kp 0, kd 5 as existing candidate",
  }
  @fs.write_file(report_file, report.stringify(indent=2), create_mode=CreateNew)
}

///|
async fn main {
  let (stage, report_file, shadow) = match @env.args()[1:] {
    [stage, report_file] => (stage, report_file, false)
    ["hold", report_file, "--shadow"] => ("hold", report_file, true)
    ["drums", report_file, "--shadow"] => ("drums", report_file, true)
    ["raised-drums", report_file, "--shadow"] =>
      ("raised-drums", report_file, true)
    ["typing-elbows", report_file, "--shadow"] =>
      ("typing-elbows", report_file, true)
    _ =>
      fail(
        "usage: hold|elbow|elbow90|drums|raised-drums|typing-elbows REPORT [--shadow for dual-elbow stages]",
      )
  }
  let mut reason = "commissioning interrupted"
  errdefer emit_event({ "kind": "stop", "reason": Json(reason) })
  let result = try commission(stage, report_file, shadow~) catch {
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
