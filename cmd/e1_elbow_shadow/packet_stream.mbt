///|
/// An inbound status packet emitted by the receive-only SDK decoder.
priv struct StatusLine {
  packet : @ankle.Packet
  motor_ids : Array[Int32]
} derive(FromJson)

///|
priv struct Branch {
  path : @elbow.Path
  simulate_elbow : Bool
  mut frames : Int32
  mut stop : String?
  mut stop_seq : Int32?
  mut peak_offset_deg : Double
  mut last_offset_deg : Double
  mut max_leg_delta : Double
}

///|
fn Branch::new(
  clip : @elbow.Clip,
  hold : Array[@low.MotorCommand],
  simulate_elbow~ : Bool,
) -> Branch raise {
  {
    path: @elbow.Path::new(clip, hold[:]),
    simulate_elbow,
    frames: 0,
    stop: None,
    stop_seq: None,
    peak_offset_deg: 0.0,
    last_offset_deg: 0.0,
    max_leg_delta: 0.0,
  }
}

///|
fn Branch::stop_at(self : Branch, reason : String, seq : Int32) -> Unit {
  if self.stop is None && self.frames < @elbow.FRAMES {
    self.path.cancel()
    self.stop = Some(reason)
    self.stop_seq = Some(seq)
  }
}

///|
fn status_sample(p : @ankle.Packet) -> @elbow.Sample {
  {
    source_ns: p.source_ns,
    receipt_ms: p.arrival_ns / 1000000L,
    motors: Array::makei(24, i => {
      id: i,
      position: p.q[i],
      velocity: p.qd[i],
      error: p.error[i],
    }),
  }
}

///|
fn Branch::record(
  self : Branch,
  p : @ankle.Packet,
  now_ms : Int64,
  clip : @elbow.Clip,
  hold : Array[@low.MotorCommand],
) -> Unit raise {
  if self.stop is Some(_) {
    return
  }
  let sample = status_sample(p)
  let elbow = @elbow.ELBOW_SLOT
  if self.simulate_elbow {
    let prev = (self.frames - 1).max(0)
    sample.motors[elbow] = {
      ..sample.motors[elbow],
      position: hold[elbow].position + clip.offset_degrees[prev] * @ankle.RAD,
    }
  }
  let frame = self.path.next(sample, now_ms) catch {
    e => {
      self.stop_at(e.to_string(), p.seq)
      return
    }
  }
  guard frame.length() == 24 else { fail("incomplete shadow candidate") }
  for i, m in frame {
    let base = hold[i]
    if @elbow.leg_slot(i) {
      self.max_leg_delta = self.max_leg_delta.max(
        (m.position - base.position).abs(),
      )
    }
    guard (i == elbow || m.position == base.position) &&
      m.velocity == base.velocity &&
      m.kp == base.kp &&
      m.kd == base.kd &&
      m.torque == base.torque else {
      fail("shadow hold changed at slot " + i.to_string())
    }
  }
  self.last_offset_deg = (frame[elbow].position - hold[elbow].position) /
    @ankle.RAD
  guard (self.last_offset_deg - clip.offset_degrees[self.frames]).abs() < 1.0e-8 else {
    fail("elbow reference mismatch")
  }
  self.peak_offset_deg = self.peak_offset_deg.min(self.last_offset_deg)
  self.frames += 1
}

///|
fn Branch::report(self : Branch) -> Json {
  {
    "candidate_frames": Json(self.frames),
    "stop": Json(self.stop),
    "stop_sequence": Json(self.stop_seq),
    "checked_leg_targets": Json(12 * self.frames),
    "max_leg_target_change_rad": self.max_leg_delta,
    "elbow_peak_offset_deg": self.peak_offset_deg,
    "elbow_last_offset_deg": self.last_offset_deg,
    "simulated_elbow_feedback": self.simulate_elbow,
  }
}

///|
fn parse_status_line(line : String) -> @ankle.Packet raise {
  let status : StatusLine = @json.from_json(@json.parse(line))
  let p = status.packet
  guard status.motor_ids.length() == 24 &&
    p.q.length() == 24 &&
    p.qd.length() == 24 &&
    p.error.length() == 24 else {
    fail("incomplete status line")
  }
  for i, id in status.motor_ids {
    guard i == id else { fail("SDK motor ID mismatch") }
  }
  p
}

///|
async fn read_status() -> @ankle.Packet {
  let input : &@io.Reader = @stdio.stdin
  guard input.read_until("\n") is Some(line) else {
    fail("end of packet stream")
  }
  parse_status_line(line)
}

///|
async fn run_packet_stream(clip_file : String, output : String) -> Unit {
  guard !@fs.exists(output) else { fail("report already exists") }
  let clip = read_reference(clip_file)
  clip.validate()
  let opening = @async.with_timeout(30000, read_status)
  let startup_spike = opening.starts_on_standing_spike()
  let first = if startup_spike {
    let recovered = @async.with_timeout(6, read_status)
    guard recovered.confirms_standing_start(opening) &&
      @env.now().reinterpret_as_int64() * 1000000L <=
      opening.arrival_ns + @ankle.CONFIRM_NS else {
      fail("unconfirmed starting ankle packet")
    }
    recovered
  } else {
    opening
  }
  let detector = @ankle.Detector::new(first, confirm_isolated=true)
  let hold = shadow_hold(clip, status_sample(first))
  let measured = Branch::new(clip, hold, simulate_elbow=false)
  let tracking = Branch::new(clip, hold, simulate_elbow=true)
  let mut p = first
  let mut count = 0
  let mut ticks = 0
  let mut waited = 0
  let mut waiting_tick = false
  let mut max_age_ms = 0L
  let mut max_late_ns = 0L
  let mut reason : String? = None
  for ;; {
    count += 1
    let now = @env.now().reinterpret_as_int64()
    let age = now - p.arrival_ns / 1000000L
    max_age_ms = max_age_ms.max(age)
    if age < 0L || age > 40L {
      reason = Some("stale or future host receipt")
      break
    }
    let due = first.arrival_ns + ticks.to_int64() * 20000000L
    if detector.pending is Some(suspect) &&
      now * 1000000L > suspect.arrival_ns + @ankle.CONFIRM_NS {
      reason = Some("ankle confirmation deadline expired")
      break
    }
    if detector.pending is Some(_) && p.arrival_ns >= due {
      waiting_tick = true
    }
    match detector.observe(p) {
      Stop(why, slot) => {
        reason = Some(why + " (slot " + slot.to_string() + ")")
        break
      }
      Wait => if p.arrival_ns >= due { waiting_tick = true }
      Use =>
        if p.arrival_ns >= due {
          measured.record(p, now, clip, hold)
          tracking.record(p, now, clip, hold)
          if waiting_tick {
            waited += 1
            waiting_tick = false
          }
          max_late_ns = max_late_ns.max(p.arrival_ns - due)
          ticks += 1
          if (measured.stop is Some(_) && tracking.stop is Some(_)) ||
            ticks == @elbow.FRAMES {
            break
          }
        }
    }
    let timeout = if detector.pending is Some(suspect) {
      // Ceil to the millisecond timer. Recheck the absolute deadline on receipt.
      ((suspect.arrival_ns + @ankle.CONFIRM_NS + 999999L) / 1000000L -
      @env.now().reinterpret_as_int64())
      .to_int()
      .max(1)
    } else {
      40
    }
    p = @async.with_timeout(timeout, read_status) catch {
      err => {
        reason = Some("packet stream stopped: " + err.to_string())
        break
      }
    }
    continue
  }
  if reason is Some(why) {
    measured.stop_at(why, p.seq)
    tracking.stop_at(why, p.seq)
  }
  let report : Json = {
    "format": "moonrobo.e1-elbow-packet-shadow.v1",
    "published": false,
    "source": "receive-only packet stream",
    "duration_ms": 15000,
    "reference_peak_deg": clip.offset_degrees[375],
    "tracking_tolerance_deg": clip.tracking_tolerance_deg(),
    "tick_ms": 20,
    "first_seq": Json(first.seq),
    "last_seq": Json(p.seq),
    "packets": Json(count),
    "first_arrival_ns": first.arrival_ns.to_string(),
    "last_arrival_ns": p.arrival_ns.to_string(),
    "wall_end_ms": @env.now().to_string(),
    "max_processing_age_ms": Json(max_age_ms.to_int()),
    "leg_guard_stop": Json(reason),
    "ankle_filter": "one isolated sample, immediate recovery within 0.1 degrees and 6 ms",
    "confirmed_startup_spike_before_first_target": startup_spike,
    "cleared_left_spikes": Json(detector.left_events),
    "cleared_right_only_spikes": Json(detector.right_only_events),
    "max_confirmation_ms": Json(
      detector.max_confirmation_ns.to_double() / 1.0e6,
    ),
    "ticks_waiting_for_confirmation": Json(waited),
    "max_receipt_tick_lag_ms": Json(max_late_ns.to_double() / 1.0e6),
    "measured_feedback": measured.report(),
    "tracking_elbow_feedback": tracking.report(),
  }
  @fs.write_file(output, report.stringify(indent=2), create_mode=CreateNew)
}
