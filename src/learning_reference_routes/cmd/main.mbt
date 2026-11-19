///|
async fn main {
  let args = @env.args()
  if args.length() == 5 && args[1] == "verify" {
    ignore(@routes.verify_actor_update_states(args[2], args[3], args[4]))
    return
  }
  guard args.length() == 6 else {
    fail("usage: final|gradient|tail SOURCE MUJOCO_LIBRARY SCENE OUTPUT")
  }
  match args[1] {
    "final" => @routes.run_final_route(args[2], args[3], args[4], args[5])
    "gradient" => @routes.run_gradient_route(args[2], args[3], args[4], args[5])
    "tail" => @routes.run_tail_directions(args[2], args[3], args[4], args[5])
    _ => fail("unknown reference route command")
  }
}
