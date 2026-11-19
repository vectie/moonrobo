///|
/// Fused forward retains the ATen cross VJP; independent from native cross.
pub fn Context::with_fused_cross_forward(
  self : Context,
  enabled : Bool,
) -> Context raise {
  guard !enabled ||
    (
      self.backend.has_geometry_tail() &&
      self.cross_preserve_forward &&
      !self.native_cross
    ) else {
    fail("fused cross requires preserve-forward mode and geometry plugin")
  }
  { ..self, fused_cross_forward: enabled, }
}
