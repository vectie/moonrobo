///|
async fn main {
  let args = @env.args()
  if args.length() == 8 && args[1] == "sustained" {
    @studies.run_sustained(args[2], args[3], args[4], args[5], args[6], args[7])
    return
  }
  if args.length() == 11 && args[1] == "learned" {
    @studies.run_learned_study(
      args[2],
      args[3],
      args[4],
      args[5],
      args[6],
      args[7],
      args[8],
      args[9],
      args[10],
    )
  } else if args.length() == 7 && args[1] == "long" {
    @studies.run_learned_long(args[2], args[3], args[4], args[5], args[6])
  } else {
    fail(
      "usage: learned LIBRARY SCENE CONFIG COLLECTION EXPERIMENT TEACHER INTERVENTION POLICIES OUTPUT | long LIBRARY SCENE CONFIG STUDY OUTPUT",
    )
  }
}
