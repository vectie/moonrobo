///|
let usage : String =
  #|telemetry_import_nmea INPUT.nmea RECIPE.json [--csv]
  #|Import checksummed recorded GPRMC/GNRMC sentences for offline exploration.
  #|Recipe: year_century (1900 or 2000), ordered channels and eligible-only row_policy.
  #|Default: full JSON report with exact-byte input/recipe SHA-256 and exclusions.
  #|--csv: available selected channels from eligible active fixes only; retain the report.
  #|UTC milliseconds, geographic degrees, knots and true course degrees. No Cartesian route, accuracy, device or control claim.

///|
fn run(args : Array[String]) -> Unit raise {
  if args.length() == 2 && (args[1] == "--help" || args[1] == "-h") {
    println(usage)
    return
  }
  guard args.length() == 3 || (args.length() == 4 && args[3] == "--csv") else {
    fail(usage)
  }
  let bytes = @fsx.read_file_to_bytes(args[1])
  let recipe_bytes = @fsx.read_file_to_bytes(args[2])
  if bytes.length() > 4194304 || recipe_bytes.length() > 65536 {
    fail("input exceeds 4 MiB or recipe exceeds 64 KiB")
  }
  let text = @utf8.decode(bytes) catch {
    _ => fail("input must be valid UTF-8")
  }
  let recipe_text = @utf8.decode(recipe_bytes) catch {
    _ => fail("recipe must be valid UTF-8")
  }
  let recipe = match @telemetry.parse_nmea_rmc_recipe(recipe_text) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  let report = match @telemetry.import_nmea_rmc(text, recipe) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  let output = if args.length() == 4 {
    match report.to_csv() {
      Ok(value) => value
      Err(message) => fail(message)
    }
  } else {
    (
      {
        "format": "moonrobo.nmea-rmc-file.v1",
        "input_file": args[1].to_json(),
        "source_sha256": @crypto.bytes_to_hex_string(@crypto.sha256(bytes)).to_json(),
        "recipe_file": args[2].to_json(),
        "recipe_sha256": @crypto.bytes_to_hex_string(
          @crypto.sha256(recipe_bytes),
        ).to_json(),
        "import": report.to_json(),
      } : Json).stringify(indent=2)
  }
  println(output.trim_end())
}

///|
fn main {
  run(@env.args()) catch {
    error => {
      eprintln(({ "error": error.to_string() } : Json).stringify())
      @sys.exit(2)
    }
  }
}
