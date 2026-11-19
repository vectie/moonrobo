///|
async fn main {
  let args = @env.args()
  guard args.length() == 5 || args.length() == 6 else {
    fail(
      "usage: initialize actor.json config.json output.json; or <fit-actor|fit-value> incoming.json train-points.json[.gz] config.json output.json",
    )
  }
  if args[1] == "initialize" {
    guard args.length() == 5 else {
      fail("initialize expects actor.json config.json output.json")
    }
    println(@temporal.run_initialize(args[2], args[3], args[4]).stringify())
    return
  }
  guard args.length() == 6 else {
    fail("fit expects incoming.json points.json config.json output.json")
  }
  let report = match args[1] {
    "initialize-value" =>
      @temporal.run_initialize_value(args[2], args[3], args[4], args[5])
    "fit-actor" =>
      @temporal.run_fit_temporal(args[2], args[3], args[4], args[5])
    "fit-value" => @temporal.run_fit_value(args[2], args[3], args[4], args[5])
    _ => fail("unknown temporal operation")
  }
  println(report.stringify())
}
