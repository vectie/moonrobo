///|
priv enum Injection {
  CapturedStep
  GradualAnkle
  Knee
}

///|
/// Keep injected faults independent of recorded ankle spikes. A ramp reaches
/// one degree after 50 ms; a clean 100 ms window covers all detection bounds.
/// The unchanged full recording is still used for the positive replay above.
fn injection_anchor(data : Array[Packet]) -> Int32? {
  let first = data[0]
  for i in 2..<data.length() {
    let elapsed = data[i].arrival_ns - first.arrival_ns
    if elapsed < 202000000L {
      continue
    }
    if elapsed > 1000000000L {
      break
    }
    let until = data[i].arrival_ns + 100000000L
    let mut clean = true
    let mut complete = false
    // Two healthy predecessors exercise the confirmation path. An injection
    // immediately after recovery should instead stop early for dense anomalies.
    for j in (i - 2)..<data.length() {
      let p = data[j]
      if [5, 6, 7, 8, 9, 10, 16, 17, 18, 19, 20, 21].any(slot => {
          (p.q[slot] - first.q[slot]).abs() > @ankle.RAD
        }) {
        clean = false
        break
      }
      if p.arrival_ns >= until {
        complete = true
        break
      }
    }
    if clean && complete {
      return Some(i)
    }
  }
  None
}

///|
/// Only in-memory copies are edited. The step repeats the four original
/// ankle displacements and velocities, so its first sample looks like a glitch.
fn inject(
  data : Array[Packet],
  at : Int32,
  example : Int32,
  kind : Injection,
  ankle_slot : Int32,
) -> Array[Packet] {
  data.mapi((i, p) => {
    let t = (p.arrival_ns - data[at].arrival_ns).to_double() / 1.0e9
    if i < at || t >= 0.2 {
      return p
    }
    let q = p.q.copy()
    let qd = p.qd.copy()
    match kind {
      CapturedStep =>
        for slot in [9, 10, 20, 21] {
          q[slot] = data[at - 1].q[slot] +
            data[example].q[slot] -
            data[example - 1].q[slot]
          qd[slot] = data[example].qd[slot]
        }
      GradualAnkle => {
        q[ankle_slot] = data[at - 1].q[ankle_slot] +
          (20.0 * t).min(2.0) * @ankle.RAD
        qd[ankle_slot] = if t < 0.1 { 20.0 * @ankle.RAD } else { 0.0 }
      }
      Knee => q[8] = data[at - 1].q[8] + 2.0 * @ankle.RAD
    }
    { ..p, q, qd, }
  })
}

///|
async fn main {
  let args = @env.args()[1:].to_owned()
  let confirm_isolated = args.last() == Some("--confirm-isolated")
  if confirm_isolated {
    ignore(args.pop())
  }
  guard args[:] is [reference, recording, output] else {
    fail("usage: e1_ankle_shadow ELBOW_REFERENCE FULL_RATE_PACKETS NEW_REPORT")
  }
  let clip : @elbow.Clip = if reference == "--gentle" {
    @elbow.Clip::gentle()
  } else {
    @json.from_json(@fs.read_file(reference).json())
  }
  let captured : Array[Packet] = @json.from_json(
    @fs.read_file(recording).json(),
  )
  let data = if captured.get(0) is Some(opening) &&
    opening.starts_on_standing_spike() {
    guard captured.get(1) is Some(next) && next.confirms_standing_start(opening) else {
      fail("unconfirmed starting ankle packet")
    }
    captured[1:].to_owned()
  } else {
    captured
  }
  guard data.length() > 1 &&
    data[data.length() - 1].arrival_ns - data[0].arrival_ns >= 15000000000L else {
    fail("15 seconds of full-rate status required")
  }
  let first = data[0]
  guard data.all(p => {
    p.q.length() == 24 && p.qd.length() == 24 && p.error.length() == 24
  }) else {
    fail("24 complete, SDK-ordered motor records required")
  }
  guard injection_anchor(data) is Some(at) &&
    data.search_by(p => p.q[10] < first.q[10] - 8.0 * @ankle.RAD)
    is Some(example) &&
    at > 0 &&
    example > 0 else {
    fail("missing in-range fixture anchors")
  }
  let baseline = replay(
    clip,
    data,
    classify=true,
    track=true,
    confirm_isolated~,
  )
  guard baseline.trip is None &&
    baseline.candidates == @elbow.FRAMES &&
    baseline.isolated_left > 0 else {
    fail(
      "recorded isolated events did not clear: " + Json(baseline).stringify(),
    )
  }
  let ankle_slot = if (data[example].q[9] - data[example - 1].q[9]).abs() >
    @ankle.RAD {
    9
  } else {
    10
  }
  let cases : Array[Json] = []
  for
    (name, kind, slot) in [
      ("matching_step", CapturedStep, ankle_slot),
      ("gradual_ankle", GradualAnkle, ankle_slot),
      ("knee_step", Knee, 8),
    ] {
    let injected = inject(data, at, example, kind, ankle_slot)
    let first_over = injected[at:]
      .search_by(p => (p.q[slot] - first.q[slot]).abs() > @ankle.RAD)
      .unwrap() +
      at
    let check = replay(
      clip,
      injected,
      classify=true,
      track=false,
      confirm_isolated~,
    )
    guard check.trip is Some(trip) && trip.slot == slot else {
      fail(
        "drift not latched at expected joint: " +
        name +
        " " +
        Json(check).stringify(),
      )
    }
    let expected = if kind is CapturedStep {
      first_over + 1
    } else {
      first_over
    }
    guard trip.sequence == data[expected].seq else {
      fail("wrong detection packet: " + name + " " + Json(check).stringify())
    }
    let strict = replay(clip, injected, classify=false, track=false)
    guard strict.trip is Some(strict_trip) &&
      strict_trip.reason.contains(
        "stationary joint drift at slot " + slot.to_string(),
      ) else {
      fail("strict path did not catch injected drift")
    }
    cases.push({
      "fixture": name,
      "first_over_sequence": Json(data[first_over].seq),
      "first_over_ms": Json(
        (data[first_over].arrival_ns - first.arrival_ns).to_double() / 1.0e6,
      ),
      "latency_ms": Json(
        (data[expected].arrival_ns - data[first_over].arrival_ns).to_double() /
        1.0e6,
      ),
      "shadow": Json(check),
      "strict": Json(strict),
    })
  }
  let strict_tracking = replay(clip, data, classify=false, track=true)
  let raw = replay(clip, data, classify=true, track=false, confirm_isolated~)
  guard raw.trip is Some(r) && r.reason.contains("elbow following error") else {
    fail("elbow guard changed")
  }
  guard strict_tracking.trip is Some(t) &&
    [9, 10, 20, 21].any(i => {
      t.reason.contains("stationary joint drift at slot " + i.to_string())
    }) else {
    fail("strict comparison changed")
  }
  let report : Json = {
    "mode": "file-only shadow replay",
    "confirm_isolated": confirm_isolated,
    "duration_ms": 15000,
    "threshold_deg": 1,
    "confirmation_deadline_ms": 6,
    "recovery_tolerance_deg": 0.1,
    "pattern_tolerance_deg": 0.15,
    "standing_pose_match_tolerance_deg": 0.02,
    "tested_ankle_slot": Json(ankle_slot),
    "drift_injection_start_sequence": Json(data[at].seq),
    "drift_injection_clean_window_ms": 100,
    "raw_legs_tracking_elbow": Json(baseline),
    "raw_legs_recorded_elbow": Json(raw),
    "strict_legs_tracking_elbow": Json(strict_tracking),
    "drift_injections": Json(cases),
  }
  @fs.write_file(output, report.stringify(indent=2), create_mode=CreateNew)
}
