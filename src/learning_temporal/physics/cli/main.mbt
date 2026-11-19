///|
async fn main {
  let args = @env.args()
  if args.length() == 9 && args[1] == "disturbance" {
    println(
      @temporal_physics.run_disturbance(
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
  guard args.length() == 7 else {
    fail(
      "usage: libmujoco scene.xml actor.json value.json config.json output-prefix",
    )
  }
  println(
    @temporal_physics.run_ppo(
      args[1],
      args[2],
      args[3],
      args[4],
      args[5],
      args[6],
    ).stringify(),
  )
}
