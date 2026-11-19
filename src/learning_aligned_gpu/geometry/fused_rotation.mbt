///|
pub fn Context::with_fused_axis_rotation(
  self : Context,
  enabled : Bool,
) -> Context raise {
  guard !enabled || self.backend.has_fused_rotation() else {
    fail("fused rotation plugin required")
  }
  { ..self, fused_axis_rotation: enabled, }
}
