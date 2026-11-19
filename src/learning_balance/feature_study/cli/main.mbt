///|
async fn main {
  let args = @env.args()
  guard args.length() == 10 else {
    fail(
      "usage: libmujoco scene.xml config.json teacher.json intervention experiment.json policies teacher-provider.mbt output",
    )
  }
  println(
    @features.run(
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
