///|
/// Compare the measured take, including any lead-in and tail, with the same
/// reference as the shadow path. The timing cue comes from the recording.
fn check_teach(
  clip : @elbow.Clip,
  packets : Array[@ankle.Packet],
  start_seq : Int32,
) -> (Bool, Json) raise {
  clip.validate()
  guard packets.get(0) is Some(first) &&
    packets.search_by(p => p.seq == start_seq) is Some(cue) else {
    fail("recorded start sequence required")
  }
  let start = packets[cue].arrival_ns
  let tick = clip.step_ms.to_int64() * 1000000L
  let last = clip.offset_degrees.length() - 1
  let duration = last.to_int64() * tick
  let detector = @ankle.Detector::new(first)
  let mut reason : String? = None
  let mut checked = 0
  let mut max_error = 0.0
  let mut min_elbow = 0.0
  let mut max_leg = 0.0
  for p in packets {
    checked += 1
    let verdict = detector.observe(p)
    if verdict is Stop(why, slot) {
      reason = Some(why + " (slot " + slot.to_string() + ")")
      break
    }
    // Slot 23 is present on the wire but outside the 23-joint model. Check
    // its raw reading for change without treating it as a calibrated joint.
    if p.q[23] != first.q[23] {
      reason = Some("additional SDK slot 23 changed")
      break
    }
    let t = (p.arrival_ns - start).clamp(min=0L, max=duration)
    let i = (t / tick).to_int()
    let fraction = (t % tick).to_double() / tick.to_double()
    let a = clip.offset_degrees[i]
    let b = clip.offset_degrees[(i + 1).min(last)]
    let measured = (p.q[@elbow.ELBOW_SLOT] - first.q[@elbow.ELBOW_SLOT]) /
      @ankle.RAD
    min_elbow = min_elbow.min(measured)
    max_error = max_error.max((measured - (a + fraction * (b - a))).abs())
    if verdict is Use {
      for slot in 0..<24 {
        if @elbow.leg_slot(slot) {
          max_leg = max_leg.max((p.q[slot] - first.q[slot]).abs() / @ankle.RAD)
        }
      }
    }
  }
  if reason is None {
    if detector.pending is Some(_) {
      reason = Some("recording ends with an unconfirmed ankle excursion")
    } else if packets[packets.length() - 1].arrival_ns - start < duration {
      reason = Some("recording ends before the full 15-second movement")
    } else if max_error > clip.tracking_tolerance_deg() {
      reason = Some("measured elbow outside reference tracking tolerance")
    }
  }
  let passed = reason is None
  let report : Json = {
    "format": "moonrobo.e1-measured-teach.v1",
    "matches_reference": passed,
    "reason": match reason {
      Some(s) => Json(s)
      None => Json::null()
    },
    "published": false,
    "tracking_tolerance_deg": clip.tracking_tolerance_deg(),
    "start_sequence": Json(start_seq),
    "checked_packets": Json(checked),
    "last_checked_sequence": Json(packets[checked - 1].seq),
    "measured_elbow_peak_offset_deg": min_elbow,
    "max_measured_elbow_reference_error_deg": max_error,
    "max_leg_drift_on_accepted_packets_deg": max_leg,
    "cleared_bilateral_spikes": Json(detector.left_events),
    "cleared_right_only_spikes": Json(detector.right_only_events),
  }
  (passed, report)
}

///|
async fn check_teach_recording(
  clip_file : String,
  recording : String,
  start : Int32,
  output : String,
) -> Unit {
  let clip = read_reference(clip_file)
  let packets : Array[@ankle.Packet] = []
  for line in @fs.read_file(recording).text().split("\n") {
    if !line.is_empty() {
      packets.push(parse_status_line(line.to_owned()))
    }
  }
  let (passed, report) = check_teach(clip, packets, start)
  @fs.write_file(output, report.stringify(indent=2), create_mode=CreateNew)
  guard passed else { fail("recorded motion did not match; see report") }
}
