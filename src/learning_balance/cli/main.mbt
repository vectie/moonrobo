///|
async fn main {
  let args = @env.args()
  if args.length() == 5 && args[1] == "export-evaluations" {
    println(
      @balance.run_export_evaluations(args[2], args[3], args[4]).stringify(),
    )
    return
  }
  if args.length() == 4 && args[1] == "export-npz" {
    println(@balance.run_export_training_npz(args[2], args[3]))
    return
  }
  guard args.length() == 4 else {
    fail("usage: <learned|sustained> train-points.json[.gz] output.json")
  }
  guard args[1] == "learned" || args[1] == "sustained" else {
    fail("unknown balance head")
  }
  println(
    @balance.run_fit(args[2], args[3], args[1] == "sustained").stringify(),
  )
}
