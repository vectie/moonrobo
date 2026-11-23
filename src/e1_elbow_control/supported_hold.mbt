///|
/// Numeric position feedback for the explicitly supported commissioning path.
/// Contains no transport or admission authority; budgets match the tested v2
/// supported-elbow profile. A fault permanently stops this owner.
pub struct SupportedHoldFeedback {
  priv state : PositionHoldState
}

///|
pub fn SupportedHoldFeedback::new(
  settings : SupportedElbowSettings,
  baseline : Sample,
) -> Self raise {
  settings.validate()
  { state: PositionHoldState::new(settings.feedback, baseline), }
}

///|
pub fn SupportedHoldFeedback::next(
  self : Self,
  sample : Sample,
  now_ms : Int64,
) -> Array[@low.MotorCommand] raise {
  self.state.next(sample, now_ms)
}
