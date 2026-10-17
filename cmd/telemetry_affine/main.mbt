///|
let usage : String =
  #|telemetry_affine INPUT.csv RECIPE.json [--format json|fit-csv|holdout-csv|normalization-recipe]
  #|Fit a recorded affine relationship, then inspect separately selected held-out rows.
  #|Recipe declares channel roles, labels, a new output name and disjoint fit/holdout windows.
  #|normalization-recipe exports a candidate for the existing explicit normalizer.
  #|Recorded-data exploration only. No physical calibration, readiness, device access or control.

///|
fn run(args : Array[String]) -> Unit raise {
  if args.length() == 2 && (args[1] == "--help" || args[1] == "-h") {
    println(usage)
    return
  }
  guard args.length() == 3 || (args.length() == 5 && args[3] == "--format") else {
    fail(usage)
  }
  let format = if args.length() == 5 { args[4] } else { "json" }
  if !["json", "fit-csv", "holdout-csv", "normalization-recipe"].contains(
      format,
    ) {
    fail("unsupported format")
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
  let recipe = match @telemetry.parse_affine_recipe(recipe_text) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  let report = match @telemetry.fit_affine_csv(text, recipe) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  let output = match format {
    "fit-csv" | "holdout-csv" => {
      let partition = if format == "fit-csv" { "fit" } else { "holdout" }
      match report.residual_csv(partition) {
        Ok(value) => value
        Err(message) => fail(message)
      }
    }
    "normalization-recipe" =>
      report.normalization_recipe().to_json().stringify(indent=2)
    _ =>
      (
        {
          "format": "moonrobo.recorded-affine-file.v1",
          "input_file": args[1].to_json(),
          "source_sha256": @crypto.bytes_to_hex_string(@crypto.sha256(bytes)).to_json(),
          "recipe_file": args[2].to_json(),
          "recipe_sha256": @crypto.bytes_to_hex_string(
            @crypto.sha256(recipe_bytes),
          ).to_json(),
          "fit": report.to_json(),
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
