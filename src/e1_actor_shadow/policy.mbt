///|
/// Borrowed E1 SMC policy view for recorded shadow execution. The caller owns
/// the numerical actor and closes it after replay/serve has returned. This view
/// contains no training, simulator, SDK, device or model resource handles.
pub struct Policy {
  priv history_frames : Int32
  priv goal_width : Int32
  priv physical_actions : Int32
  priv predict : (Array[Array[Double]], Array[Double]) -> Array[Double] raise
  priv nominal_setpoints : (ArrayView[Double]) -> Array[Double] raise
}

///|
pub fn Policy::new(
  history_frames~ : Int32,
  goal_width~ : Int32,
  physical_actions~ : Int32,
  predict~ : (Array[Array[Double]], Array[Double]) -> Array[Double] raise,
  nominal_setpoints~ : (ArrayView[Double]) -> Array[Double] raise,
) -> Self raise {
  guard history_frames > 0 &&
    history_frames <= 10 &&
    goal_width > 0 &&
    goal_width <= 730 &&
    goal_width % 73 == 0 &&
    (physical_actions == 23 || physical_actions == 24) else {
    fail("invalid E1 SMC shadow policy dimensions")
  }
  { history_frames, goal_width, physical_actions, predict, nominal_setpoints, }
}

///|
pub fn Policy::from_actor(actor : @actor.Actor) -> Self raise {
  let bundle = actor.bundle()
  guard bundle.observation_width() == 99 else {
    fail("shadow execution requires the99-feature SMC actor")
  }
  Policy::new(
    history_frames=bundle.history_frames(),
    goal_width=bundle.goal_width(),
    physical_actions=bundle.joints().length(),
    predict=(history, goals) => actor.forward_embedded(history, goals),
    nominal_setpoints=actions => bundle.nominal_setpoints(actions),
  )
}

///|
fn finite(value : Double) -> Bool {
  value == value && value - value == 0.0
}
