///|
fn[T] need(result : Result[T, String]) -> T raise {
  match result {
    Ok(value) => value
    Err(message) => fail(message)
  }
}

///|
fn run(args : Array[String]) -> Unit raise {
  if args.length() == 3 && args[1] == "list" {
    let values = need(@learning.list(args[2]))
    println(values.to_json().stringify(indent=2))
  } else if args.length() == 4 && args[1] == "inspect" {
    let value = need(@learning.inspect(args[2], args[3]))
    println(value.to_json().stringify(indent=2))
  } else if args.length() == 6 && args[1] == "import" {
    let value = need(
      @learning.import_run(
        args[2],
        args[3],
        args[4],
        @string.parse_int64(args[5]),
      ),
    )
    println(value.to_json().stringify(indent=2))
  } else {
    fail(
      "usage: learning_experiment import MOONDATA_ROOT RUN_DIR ID NOW_MS | list ROOT | inspect ROOT ID",
    )
  }
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
