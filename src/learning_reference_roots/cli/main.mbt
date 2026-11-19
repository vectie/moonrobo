///|
async fn main {
  let args = @env.args()
  guard args.length() >= 2 else {
    fail("usage: integration|decomposition|export ...")
  }
  match args[1] {
    "integration" => {
      guard args.length() == 7 else {
        fail(
          "integration source-study libmujoco scene.xml output-study provider.mbt",
        )
      }
      println(
        @roots.run_integration(args[2], args[3], args[4], args[5], args[6]).stringify(),
      )
    }
    "decomposition" => {
      guard args.length() == 4 else { fail("decomposition study provider.mbt") }
      println(@roots.run_decomposition(args[2], args[3]).stringify())
    }
    "export" => {
      guard args.length() == 5 else { fail("export study libmujoco scene.xml") }
      @roots.export_stream(args[2], args[3], args[4], fn(row) {
        println(row.stringify())
      })
    }
    _ => fail("unknown reference root diagnostic command")
  }
}
