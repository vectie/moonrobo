///|
async fn main {
  let args = @env.args()
  let options : Map[String, String] = {}
  for i = 1; i < args.length(); i = i + 2 {
    guard i + 1 < args.length() &&
      ["--initial", "--corrected", "--validation", "--test", "--output"].contains(
        args[i],
      ) &&
      !options.contains(args[i]) else {
      fail(
        "expected unique --initial --corrected --validation --test --output options",
      )
    }
    options[args[i]] = args[i + 1]
  }
  fn required(name : String) -> String raise {
    guard options.get(name) is Some(value) else { fail("missing " + name) }
    value
  }
  println(
    @comparison.run(
      required("--initial"),
      required("--corrected"),
      required("--validation"),
      required("--test"),
      required("--output"),
    ).stringify(indent=2),
  )
}
