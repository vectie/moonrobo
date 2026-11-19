///|
fn main raise {
  let args = @env.args()
  guard args.length() == 6 else {
    fail(
      "usage: learning_replay_register MOONDATA_ROOT EXPERIMENT_ID REPLAY_JSON ASSET_DIR NOW_MS",
    )
  }
  let now_ms = @string.parse_int64(args[5])
  let value = match
    @moondata_learning.attach_replay(
      args[1],
      args[2],
      args[3],
      asset_root=args[4],
      now_ms~,
    ) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  println(value.stringify(indent=2))
}
