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
  let metadata = @learned.export_learned(
    argument(args, "--study"),
    argument(args, "--long"),
    argument(args, "--library"),
    argument(args, "--scene"),
    argument(args, "--output"),
    teacher_provider_source=argument(
      args,
      "--teacher-provider-source",
      fallback="",
    ),
    provider_source=argument(
      args,
      "--provider-source",
      fallback="src/learning_registry/learned/export.mbt",
    ),
  )
  println(metadata.stringify(indent=2))
}
