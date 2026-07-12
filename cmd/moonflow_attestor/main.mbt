///|
fn option(args : Array[String], name : String) -> String raise {
  for index in 0..<(args.length() - 1) {
    if args[index] == name {
      return args[index + 1]
    }
  }
  fail("MoonRobo Flow attestor requires \{name}")
}

///|
async fn main {
  let args = @env.args()[1:].to_owned()
  @flow_attestor.attest(
    option(args, "--workspace"),
    option(args, "--request"),
    option(args, "--result"),
    option(args, "--attestation"),
    option(args, "--attestor-id"),
    option(args, "--draft"),
    option(args, "--final"),
  ) catch {
    error => {
      println(({ "accepted": false, "error": "\{error}" } : Json).stringify())
      @sys.exit(1)
    }
  }
}
