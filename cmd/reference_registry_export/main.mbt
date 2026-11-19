///|
async fn main {
  let args = @env.args()
  guard args.length() == 9 else {
    fail(
      "usage: moon run --target native cmd/reference_registry_export -- initialization|learning STUDY REFERENCES|METHOD VERIFICATION MUJOCO_LIBRARY SCENE OUTPUT PROVIDER_SOURCE.mbt",
    )
  }
  let runtime = @physics.Runtime::open(args[5], args[6])
  let metadata = match args[1] {
    "initialization" =>
      @reference.export_initialization_registry(
        args[2],
        args[3],
        args[4],
        runtime,
        args[7],
        args[8],
      )
    "learning" =>
      @reference.export_learning_registry(
        args[2],
        args[4],
        runtime,
        args[3],
        args[7],
      )
    _ => fail("expected initialization or learning registry mode")
  }
  println(metadata.stringify())
}
