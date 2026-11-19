///|
/// Native teachers identify the real implementation; legacy files retain
/// their original Python identity. Source bytes must still match exactly.
fn teacher_provider_source(teacher : Json) -> String raise {
  guard teacher is Object(fields) else { fail("teacher must be an object") }
  match fields.get("source_language") {
    Some(String("moonbit")) =>
      match fields.get("provider_source") {
        Some(String(source)) if source.has_suffix(".mbt") => source
        _ => fail("native teacher requires its actual .mbt provider_source")
      }
    None | Some(String("python")) =>
      "providers/motion_learning/balance_teacher.py"
    _ => fail("unsupported teacher source language")
  }
}
