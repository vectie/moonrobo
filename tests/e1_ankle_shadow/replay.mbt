///|
priv struct Trip {
  reason : String
  slot : Int32
  sequence : Int32
  elapsed_ms : Double
} derive(ToJson)

///|
priv struct Trial {
  candidates : Int32
  trip : Trip?
  isolated_left : Int32
  isolated_right_only : Int32
  max_confirmation_ms : Double
  delayed_ticks : Int32
  max_tick_delay_ms : Double
  max_leg_target_change_rad : Double
  elbow_peak_offset_deg : Double
  elbow_final_offset_deg : Double
} derive(ToJson)

///|
fn replay(
  clip : @elbow.Clip,
  data : Array[Packet],
  classify~ : Bool,
  track~ : Bool,
  confirm_isolated~ : Bool = false,
) -> Trial raise {
  let first = data[0]
  let hold : Array[@low.MotorCommand] = Array::makei(24, i => {
    position: if i == 23 {
      0.375
    } else {
      first.q[i]
    },
    velocity: 0.0,
    kp: i.to_double() + 1.0,
    kd: (i + 1).to_double() / 100.0,
    torque: (i + 1).to_double() / 1000.0,
  })
  let path = @elbow.Path::new(clip, hold[:])
  let detector = Detector::new(first, confirm_isolated~)
  let mut next = 0
  let mut count = 0
  let mut trip : Trip? = None
  let mut peak = 0.0
  let mut last_offset = 0.0
  let mut max_leg = 0.0
  let mut delayed = 0
  let mut max_delay = 0L
  let mut prev_sample : @elbow.Sample? = None
  for tick in 0..<@elbow.FRAMES {
    let due = first.arrival_ns + tick.to_int64() * 20000000L
    let mut now = due
    // Feed all packets already received. When the last one is provisional,
    // advance the virtual clock to confirmation before permitting this tick.
    while next < data.length() {
      let p = data[next]
      if p.arrival_ns > due && (!classify || detector.pending is None) {
        break
      }
      if detector.pending is Some(suspect) &&
        p.arrival_ns > suspect.arrival_ns + @ankle.CONFIRM_NS {
        trip = Some({
          reason: "confirmation timed out",
          slot: -1,
          sequence: suspect.seq,
          elapsed_ms: (suspect.arrival_ns + @ankle.CONFIRM_NS - first.arrival_ns).to_double() /
          1.0e6,
        })
        break
      }
      if classify {
        match detector.observe(p) {
          Stop(reason, slot) => {
            trip = Some({
              reason,
              slot,
              sequence: p.seq,
              elapsed_ms: (p.arrival_ns - first.arrival_ns).to_double() / 1.0e6,
            })
            break
          }
          Wait | Use => ()
        }
      }
      now = now.max(p.arrival_ns)
      next += 1
    }
    if trip is Some(_) {
      break
    }
    let p = if classify { detector.good } else { data[next - 1] }
    if detector.pending is Some(_) || now - p.arrival_ns > @ankle.CONFIRM_NS {
      trip = Some({
        reason: "missing fresh confirming status",
        slot: -1,
        sequence: data[next - 1].seq,
        elapsed_ms: (now - first.arrival_ns).to_double() / 1.0e6,
      })
      break
    }
    if now > due {
      delayed += 1
      max_delay = max_delay.max(now - due)
    }
    let motors : Array[@elbow.Motor] = Array::makei(24, i => {
      let position = if track && i == @elbow.ELBOW_SLOT {
        hold[i].position + clip.offset_degrees[(tick - 1).max(0)] * @ankle.RAD
      } else {
        p.q[i]
      }
      { id: i, position, velocity: p.qd[i], error: p.error[i], }
    })
    let sample : @elbow.Sample = {
      source_ns: p.source_ns,
      receipt_ms: p.arrival_ns / 1000000L,
      motors,
    }
    prev_sample = Some(sample)
    let frame = path.next(sample, now / 1000000L) catch {
      err => {
        trip = Some({
          reason: err.to_string(),
          slot: -1,
          sequence: p.seq,
          elapsed_ms: (now - first.arrival_ns).to_double() / 1.0e6,
        })
        break
      }
    }
    for slot, m in frame {
      if @elbow.leg_slot(slot) {
        max_leg = max_leg.max((m.position - hold[slot].position).abs())
      }
      guard m.velocity == hold[slot].velocity &&
        m.torque == hold[slot].torque &&
        m.kp == hold[slot].kp &&
        m.kd == hold[slot].kd &&
        (slot == @elbow.ELBOW_SLOT || m.position == hold[slot].position) else {
        fail("hold changed")
      }
    }
    last_offset = (
        frame[@elbow.ELBOW_SLOT].position - hold[@elbow.ELBOW_SLOT].position
      ) /
      @ankle.RAD
    guard (last_offset - clip.offset_degrees[tick]).abs() < 1.0e-8 else {
      fail("reference mismatch")
    }
    peak = peak.min(last_offset)
    count += 1
  }
  if trip is Some(_) {
    path.cancel()
  }
  if prev_sample is Some(s) {
    let stopped = try {
      ignore(path.next(s, s.receipt_ms))
      false
    } catch {
      _ => true
    }
    guard stopped else { fail("emitted following stop or completion") }
  }
  {
    candidates: count,
    trip,
    isolated_left: detector.left_events,
    isolated_right_only: detector.right_only_events,
    max_confirmation_ms: detector.max_confirmation_ns.to_double() / 1.0e6,
    delayed_ticks: delayed,
    max_tick_delay_ms: max_delay.to_double() / 1.0e6,
    max_leg_target_change_rad: max_leg,
    elbow_peak_offset_deg: peak,
    elbow_final_offset_deg: last_offset,
  }
}
