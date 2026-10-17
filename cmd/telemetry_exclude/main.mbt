///|
let usage : String =
  #|telemetry_exclude INPUT.csv RECIPE.json [--csv [--segment INDEX]]
  #|Preview closed-interval exclusions; default JSON preserves all original observations.
  #|CSV exports one zero-based retained segment; no crossing excluded intervals or large gaps.
  #|Keep JSON, recipe and raw CSV together. Editor labels/reasons are unverified annotations.
  #|No input file writes, interpolation, physical operation or safety qualification.

///|
fn run(args : Array[String]) -> Unit raise {
  if args.length() == 2 && (args[1] == "--help" || args[1] == "-h") {
    println(usage)
    return
  }
  guard args.length() >= 3 else { fail(usage) }
  let mut csv = false
  let mut segment : Int? = None
  let seen : Array[String] = []
  for i = 3; i < args.length(); {
    let flag = args[i]
    guard !seen.contains(flag) else { fail("duplicate option: " + flag) }
    seen.push(flag)
    match flag {
      "--csv" => {
        csv = true
        continue i + 1
      }
      "--segment" => {
        guard i + 1 < args.length() else { fail("--segment requires INDEX") }
        segment = Some(@string.parse_int(args[i + 1]))
        continue i + 2
      }
      _ => fail("unknown option: " + flag)
    }
  }
  guard csv || segment is None else { fail("--segment requires --csv") }
  let bytes = @fsx.read_file_to_bytes(args[1])
  let recipe_bytes = @fsx.read_file_to_bytes(args[2])
  guard bytes.length() <= 4194304 else { fail("input exceeds 4 MiB") }
  guard recipe_bytes.length() <= 262144 else { fail("recipe exceeds 256 KiB") }
  let recipe = match
    @telemetry.parse_exclusion_recipe(@utf8.decode(recipe_bytes)) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  let report = match @telemetry.exclude_csv(@utf8.decode(bytes), recipe) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  if csv {
    let result = match report.to_csv(segment?) {
      Ok(value) => value
      Err(message) => fail(message)
    }
    println(result.trim_end())
  } else {
    println(
      (
        {
          "format": "moonrobo.telemetry-exclusion-file.v1",
          "source_sha256": @crypto.bytes_to_hex_string(@crypto.sha256(bytes)).to_json(),
          "recipe_sha256": @crypto.bytes_to_hex_string(
            @crypto.sha256(recipe_bytes),
          ).to_json(),
          "edit": report.to_json(),
        } : Json).stringify(indent=2),
    )
  }
}

///|
fn main {
  run(@env.args()) catch {
    error => {
      println("telemetry_exclude: \{error}")
      @sys.exit(1)
    }
  }
}
