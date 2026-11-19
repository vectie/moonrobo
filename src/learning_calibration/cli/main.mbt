///|
async fn main {
  let args = @env.args()
  guard args.length() == 8 && args[1] == "noise" else {
    fail(
      "usage: moon run src/learning_calibration/cli -- noise MUJOCO_LIBRARY SCENE CONFIG COLLECTION POLICIES OUTPUT",
    )
  }
  println(
    @calibration.calibrate_noise(
      args[2],
      args[3],
      args[4],
      args[5],
      args[6],
      args[7],
    ).stringify(indent=2),
  )
}
