///|
async fn supported_hold_profile() -> @elbow.SupportedElbowSettings? {
  match @env.get_env_var("MOONROBO_E1_ACTOR_HOLD_PROFILE") {
    None => None
    Some(path) => {
      let profile : @elbow.SupportedElbowSettings = @json.from_json(
        @fs.read_file(path).json(),
      )
      profile.validate()
      Some(profile)
    }
  }
}

///|
fn hold_metadata(
  profile : @elbow.SupportedElbowSettings,
  seed : Status,
  input : Status,
  now_ms : Int64,
) -> Json {
  {
    "format": "moonrobo.e1-actor-position-hold.v1",
    "power_qualified": false,
    "profile": profile.to_json(),
    "settings": profile.feedback.to_json(),
    "seed_packet_sequence": Json(seed.packet.seq),
    "seed_arrival_ns": seed.packet.arrival_ns.to_string(),
    "seed_source_ns": seed.packet.source_ns.to_string(),
    "seed_position": Json(seed.packet.q),
    "input_packet_sequence": Json(input.packet.seq),
    "input_arrival_ns": input.packet.arrival_ns.to_string(),
    "input_source_ns": input.packet.source_ns.to_string(),
    "input_position": Json(input.packet.q),
    "input_velocity": Json(input.packet.qd),
    "update_ms": now_ms.to_string(),
  }
}
