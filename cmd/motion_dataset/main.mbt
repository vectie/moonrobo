///|
fn run(args : Array[String]) -> Unit raise {
  guard args.length() == 4 || args.length() == 5 else {
    fail(
      "usage: motion_dataset INPUT.json train|validation|test WINDOW_LENGTH [STRIDE]",
    )
  }
  let dataset = match @learning.parse(@fsx.read_file_to_string(args[1])) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  let length = @string.parse_int(args[3])
  let stride = if args.length() == 5 { @string.parse_int(args[4]) } else { 1 }
  let batch = match dataset.windows(split=args[2], length~, stride~) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  println(batch.to_json().stringify(indent=2))
}

///|
fn main {
  run(@env.args()) catch {
    error => {
      println(error.to_string())
      @sys.exit(2)
    }
  }
}
