///|
fn argument(
  args : Array[String],
  name : String,
  fallback? : String,
) -> String raise {
  for i, arg in args {
    if arg == name {
      guard i + 1 < args.length() else { fail("missing value for " + name) }
      return args[i + 1]
    }
  }
  guard fallback is Some(value) else { fail("required option: " + name) }
  value
}

///|
async fn main {
  let args = @env.args()
  let report = @study.run(
    argument(args, "--library"),
    argument(args, "--scene"),
    argument(args, "--config"),
    argument(args, "--collection"),
    argument(args, "--teacher-study"),
    argument(args, "--output"),
    teacher_provider_source=argument(
      args,
      "--teacher-provider-source",
      fallback="src/learning_balance/physics/teacher.mbt",
    ),
    teacher_kernel_source=argument(
      args,
      "--teacher-kernel-source",
      fallback="src/learning_balance/teacher.mbt",
    ),
    provider_source=argument(
      args,
      "--provider-source",
      fallback="src/learning_balance/reference_study/run.mbt",
    ),
    reference_provider_source=argument(
      args,
      "--reference-provider-source",
      fallback="src/learning_balance/physics/reference.mbt",
    ),
  )
  println(report.stringify())
}
