///|
async fn main {
  let args = @env.args()
  guard args.length() == 11 else {
    fail(
      "usage: refine|value MUJOCO_LIBRARY SCENE CONFIG EXPERIMENT COLLECTION TEACHER_DATA POLICIES DYNAMICS OUTPUT",
    )
  }
  match args[1] {
    "refine" =>
      @refinement.run_refinement(
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
    "value" =>
      @refinement.run_value_training(
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
    _ => fail("refinement command must be refine or value")
  }
}
