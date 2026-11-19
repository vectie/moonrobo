///|
async fn main {
  let args = @env.args()
  guard args.length() == 6 && args[1] == "sustained" else {
    fail(
      "usage: moon run src/learning_registry/cli -- sustained STUDY MUJOCO_LIBRARY SCENE OUTPUT",
    )
  }
  println(
    @registry.export_sustained(args[2], args[3], args[4], args[5]).stringify(
      indent=2,
    ),
  )
}
