///|
pub fn Context::with_fused_cross_vjp(
  self : Context,
  enabled : Bool,
) -> Context raise {
  guard !enabled ||
    (
      self.backend.has_geometry_vjp() &&
      self.fused_cross_forward &&
      self.cross_preserve_forward &&
      !self.native_cross
    ) else {
    fail("joint cross VJP requires fused forward and geometry VJP plugin")
  }
  { ..self, fused_cross_vjp: enabled, }
}
