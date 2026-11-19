///|
async fn main {
  let args = @env.args()
  if args.length() == 8 && args[1] == "refit" {
    @training.run_refit(args[2], args[3], args[4], args[5], args[6], args[7])
    return
  }
  guard args.length() == 6 else {
    fail(
      "usage: moon run src/learning_training/cmd -- TRAIN VALIDATION TEST CONFIG OUTPUT",
    )
  }
  @training.run_dynamics(args[1], args[2], args[3], args[4], args[5])
}
