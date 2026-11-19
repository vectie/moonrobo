///|
/// Add opt-in execution storage without discounting any historical envelope.
/// Applying the reserve to every phase also covers allocator cache retention
/// after the candidate's live tensors have been released.
pub fn Plan::with_execution_reserve(
  self : Plan,
  extra : Map[String, Int64],
) -> Plan raise {
  if extra.is_empty() {
    return self
  }
  let mut bytes = 0L
  for name, value in extra {
    guard name.has_prefix("execution_") && value > 0L && value <= 8589934592L else {
      fail("invalid bounded execution reserve")
    }
    guard !self.counts.contains(name) else {
      fail("duplicate execution reserve")
    }
    bytes = add(bytes, value)
  }
  guard bytes <= 17179869184L else { fail("execution reserve exceeds 16 GiB") }
  let phases = self.phases.map(p => {
    let components = p.components.copy()
    for name, value in extra {
      components[name] = value
    }
    { ..p, components, envelope_bytes: add(p.envelope_bytes, bytes), }
  })
  let counts = self.counts.copy()
  for name, value in extra {
    counts[name] = value
  }
  let device = self.device_phase_working_bytes.copy()
  for name, value in self.device_phase_working_bytes {
    device[name] = add(value, bytes)
  }
  let assumptions = self.assumptions.copy()
  assumptions.push(
    "Opt-in execution storage is added to every phase, including possible allocator retention; baseline envelopes are unchanged.",
  )
  let peak_bytes = add(self.peak_bytes, bytes)
  {
    ..self,
    phases,
    peak_bytes,
    required_remaining_bytes: ceil_div(mul(peak_bytes, 100L), 65L),
    full_replacement_restore_peak_bytes: add(
      self.full_replacement_restore_peak_bytes,
      bytes,
    ),
    counts,
    device_phase_working_bytes: device,
    assumptions,
  }
}
