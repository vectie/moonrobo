///|
async fn main {
  let args = @env.args()
  if args.length() == 8 && args[1] == "long-fit" {
    println(
      @study.run_long(args[2], args[3], args[4], args[5], args[6], args[7]).stringify(),
    )
    return
  }
  guard args.length() == 8 || args.length() == 9 else {
    fail(
      "usage: <fit|evaluate|collect|develop> libmujoco scene.xml experiment.json config.json output provider.mbt [teacher.json]; or long-fit libmujoco scene.xml source-study config.json output provider.mbt",
    )
  }
  println(
    @study.run(
      args[2],
      args[3],
      args[4],
      args[5],
      args[6],
      args[1],
      args[7],
      teacher_path?=if args.length() == 9 { Some(args[8]) } else { None },
    ).stringify(),
  )
}
