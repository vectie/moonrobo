///|
async fn main {
  let args = @env.args()
  guard args.length() == 2 else { fail("usage: study-folder") }
  println(@verify.run(args[1]).stringify())
}
