///|
async fn main {
  let args = @env.args()
  if args.length() == 9 && args[1] == "long" {
    println(
      @intervention.run_long(
        args[2],
        args[3],
        args[4],
        args[5],
        args[6],
        args[7],
        args[8],
      ).stringify(),
    )
    return
  }
  guard args.length() == 10 else {
    fail(
      "usage: libmujoco scene.xml config.json collection.json experiment.json teacher.json policies provider.mbt output",
    )
  }
  println(
    @intervention.run(
      args[1],
      args[2],
      args[3],
      args[4],
      args[5],
      args[6],
      args[7],
      args[8],
      args[9],
    ).stringify(),
  )
}
