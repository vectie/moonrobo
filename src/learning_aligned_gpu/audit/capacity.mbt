///|
/// The saved identity selects bounds. Shape-based inference would silently
/// upgrade old checkpoints and is deliberately forbidden.
fn checkpoint_capacity(
  identity : Json,
  streaming : Bool,
) -> @capacity.CapacityProfile raise {
  guard identity is { "config": Object(config), .. } else {
    fail("checkpoint identity must contain a configuration object")
  }
  let profile = match config.get("capacity_profile") {
    None => @capacity.Initial
    Some(String(name)) => @capacity.CapacityProfile::parse(name)
    _ => fail("checkpoint capacity_profile must be an explicit string")
  }
  guard streaming || profile == @capacity.Initial else {
    fail("paper-4096 checkpoints require stream-v2; legacy JSON is unsupported")
  }
  profile
}

///|
fn validate_capacity_state(
  state : Json,
  streaming : Bool,
) -> @capacity.CapacityProfile raise {
  guard state
    is {
      "identity": identity,
      "runtime": {
        "num_envs": environments,
        "capacity": replay_steps,
        "config": { "wm_batch": world_batch, "policy_batch": policy_batch, .. },
        ..
      },
      ..
    } else {
    fail("checkpoint identity or runtime capacity dimensions are missing")
  }
  let profile = checkpoint_capacity(identity, streaming)
  ignore(
    profile.validate_dimensions(
      environments=@json.from_json(environments),
      world_batch=@json.from_json(world_batch),
      policy_batch=@json.from_json(policy_batch),
      replay_steps=@json.from_json(replay_steps),
    ),
  )
  profile
}

///|
fn validate_sampler(saved : @aligned.SamplerCheckpointV2) -> Unit raise {
  guard saved.format == "moonrobo.return-sampler-stream.v2" && saved.bins > 0 else {
    fail("unsupported sampler stream metadata")
  }
  @aligned.checkpoint_blob(saved.returns, "sampler.returns.f64le", "f64le", [
    saved.bins,
  ])
  @aligned.checkpoint_blob(saved.average, "sampler.average.f64le", "f64le", [
    saved.bins,
  ])
  @aligned.checkpoint_blob(
    saved.completed,
    "sampler.completed.i32le",
    "i32le",
    [saved.bins],
  )
}
