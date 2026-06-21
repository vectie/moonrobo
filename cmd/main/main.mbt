///|
/// Entry point for the CLI or runnable program in this template.
/// Keep main focused; move logic into the library package.
/// Run with `moon run cmd/main` from the project root.
fn main {
  let profile = @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01")
  let report = @core.validate_robot_profile(profile)
  if report.valid {
    println("Moonrobo core ready: \{profile.label}")
  } else {
    println("Moonrobo core profile invalid: \{report.issues.length()} issue(s)")
  }
}
