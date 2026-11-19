///|
fn required(args : Array[String], name : String) -> String raise {
  for i, arg in args {
    if arg == name {
      guard i + 1 < args.length() else { fail("missing value for " + name) }
      return args[i + 1]
    }
  }
  fail("required option: " + name)
}

///|
async fn main {
  let args = @env.args()
  let report = @verification.verify(
    required(args, "--study"),
    required(args, "--incoming"),
    required(args, "--library"),
    required(args, "--scene"),
    required(args, "--output"),
  )
  println(report.stringify())
}
