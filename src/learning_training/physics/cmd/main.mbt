///|
async fn main {
  let args = @env.args()
  if args.length() == 8 && args[1] == "counterfactual" {
    @runner.run_counterfactual(
      args[2],
      args[3],
      args[4],
      args[5],
      args[6],
      args[7],
    )
    return
  }
  if args.length() == 8 && args[1] == "cloning" {
    @runner.run_supervised(args[2], args[3], args[4], args[5], args[6], args[7])
    return
  }
  if args.length() == 11 && args[1] == "aggregation" {
    @runner.run_supervised(
      args[2],
      args[3],
      args[4],
      args[5],
      args[6],
      args[7],
      policies_directory=args[8],
      teacher_path=args[9],
      collection_path=args[10],
    )
    return
  }
  if (args.length() == 9 || args.length() == 10) && args[1] == "ppo" {
    let warm_start_directory = if args.length() == 10 {
      Some(args[9])
    } else {
      None
    }
    @runner.run_ppo(
      args[2],
      args[3],
      args[4],
      args[5],
      args[6],
      args[7],
      args[8],
      warm_start_directory?,
    )
    return
  }
  guard args.length() == 8 || args.length() == 9 else {
    fail(
      "usage: moon run src/learning_training/physics/cmd -- TRAIN DYNAMICS MUJOCO_LIBRARY SCENE CONFIG EXPERIMENT OUTPUT [WARM_START_DIRECTORY]",
    )
  }
  let warm_start_directory = if args.length() == 9 {
    Some(args[8])
  } else {
    None
  }
  @runner.run_policy(
    args[1],
    args[2],
    args[3],
    args[4],
    args[5],
    args[6],
    args[7],
    warm_start_directory?,
  )
}
