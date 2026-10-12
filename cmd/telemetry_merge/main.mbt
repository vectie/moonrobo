///|
let usage : String =
  #|telemetry_merge PRIMARY.csv SECONDARY.csv [--primary-prefix LABEL] [--secondary-prefix LABEL] [--secondary-offset-ms SIGNED_MS] [--tolerance-ms MS] [--csv]
  #|Combine numeric channels on the primary recorded timestamp grid. Default: JSON report.
  #|Defaults: prefixes primary/secondary, zero offset, exact timestamp matches only.
  #|Offset adds to secondary timestamps. Tolerance permits nearest observed samples.
  #|Ties prefer earlier samples; reuse is allowed and reported. No clock/unit inference.
  #|--csv exports complete merged rows only; keep the JSON report for source timestamps and gaps.

///|
fn report_error(message : String) -> Unit {
  println(({ "error": message } : Json).stringify())
  @sys.exit(2)
}

///|
fn argument_ms(text : String, flag : String) -> Int64 raise {
  @string.parse_int64(text) catch {
    _ => fail("invalid integer for " + flag)
  }
}

///|
fn run(args : Array[String]) -> Unit raise {
  if args.length() == 2 && (args[1] == "--help" || args[1] == "-h") {
    println(usage)
    return
  }
  guard args.length() >= 3 else { fail(usage) }
  let mut primary_prefix = "primary"
  let mut secondary_prefix = "secondary"
  let mut secondary_offset_ms = 0L
  let mut tolerance_ms = 0L
  let mut csv = false
  let seen : Array[String] = []
  for i = 3; i < args.length(); {
    let flag = args[i]
    if seen.contains(flag) {
      fail("duplicate option: " + flag)
    }
    seen.push(flag)
    if flag == "--csv" {
      csv = true
      continue i + 1
    }
    match flag {
      "--primary-prefix"
      | "--secondary-prefix"
      | "--secondary-offset-ms"
      | "--tolerance-ms" => {
        guard i + 1 < args.length() else { fail("missing value for " + flag) }
        let value = args[i + 1]
        match flag {
          "--primary-prefix" => primary_prefix = value
          "--secondary-prefix" => secondary_prefix = value
          "--secondary-offset-ms" =>
            secondary_offset_ms = argument_ms(value, flag)
          _ => tolerance_ms = argument_ms(value, flag)
        }
        continue i + 2
      }
      _ => fail("unknown option: " + flag)
    }
  }
  let primary = @fsx.read_file_to_string(args[1]) catch {
    _ => fail("cannot read primary CSV")
  }
  let secondary = @fsx.read_file_to_string(args[2]) catch {
    _ => fail("cannot read secondary CSV")
  }
  let result = match
    @telemetry.merge_csv(
      primary,
      secondary,
      primary_prefix~,
      secondary_prefix~,
      secondary_offset_ms~,
      tolerance_ms~,
    ) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  if csv {
    match result.to_csv() {
      Ok(value) => println(value.trim_end())
      Err(message) => fail(message)
    }
  } else {
    println(
      (
        {
          "primary_file": args[1].to_json(),
          "secondary_file": args[2].to_json(),
          "merge": result.to_json(),
        } : Json).stringify(indent=2),
    )
  }
}

///|
fn main {
  run(@env.args()) catch {
    error => report_error(error.to_string())
  }
}
