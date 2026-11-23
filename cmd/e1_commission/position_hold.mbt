///|
/// This experimental owner has no command transport and is admitted only by
/// the hold stage's shadow branch. Metadata binds every update to raw capture.
priv struct PositionHoldExperiment {
  settings : @elbow.PositionHoldSettings
  baseline : @ankle.Packet
  owner : @elbow.PositionHoldShadow?
  trial : @elbow.PositionHoldTrial?
  trial_profile : @elbow.PositionHoldTrialSettings?
}

///|
fn PositionHoldExperiment::new(
  settings : @elbow.PositionHoldSettings,
  baseline : @ankle.Packet,
  shadow~ : Bool,
) -> Self raise {
  {
    settings,
    baseline,
    owner: Some(
      @elbow.PositionHoldShadow::new(settings, status_sample(baseline), shadow~),
    ),
    trial: None,
    trial_profile: None,
  }
}

///|
fn PositionHoldExperiment::new_trial(
  settings : @elbow.PositionHoldTrialSettings,
  baseline : @ankle.Packet,
) -> Self raise {
  {
    settings: settings.feedback,
    baseline,
    owner: None,
    trial: Some(
      @elbow.PositionHoldTrial::new(settings, status_sample(baseline)),
    ),
    trial_profile: Some(settings),
  }
}

///|
fn PositionHoldExperiment::next(
  self : Self,
  packet : @ankle.Packet,
  now_ms : Int64,
  shadow~ : Bool,
) -> (Array[@low.MotorCommand], Json) raise {
  let commands = if self.owner is Some(owner) {
    owner.next(status_sample(packet), now_ms, shadow~)
  } else {
    self.trial.unwrap().next(status_sample(packet), now_ms)
  }
  let metadata : Json = {
    "settings": self.settings.to_json(),
    "power_qualified": false,
    "trial_profile": self.trial_profile
    .map(p => p.to_json())
    .unwrap_or(Json::null()),
    "seed_packet_sequence": Json(self.baseline.seq),
    "seed_arrival_ns": self.baseline.arrival_ns.to_string(),
    "seed_source_ns": self.baseline.source_ns.to_string(),
    "seed_position": Json(self.baseline.q),
    "input_packet_sequence": Json(packet.seq),
    "input_arrival_ns": packet.arrival_ns.to_string(),
    "input_source_ns": packet.source_ns.to_string(),
    "input_position": Json(packet.q),
    "input_velocity": Json(packet.qd),
  }
  (commands, metadata)
}
