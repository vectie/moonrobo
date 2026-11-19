///|
pub fn Context::with_compact_heading(
  self : Context,
  enabled : Bool,
) -> Context raise {
  guard !enabled || self.backend.has_compact_heading() else {
    fail("compact heading plugin required")
  }
  { ..self, compact_heading: enabled, }
}
