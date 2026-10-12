///|
let usage : String =
  #|telemetry_scan INPUT.jsonl FRAME_ID SCAN_INDEX [--csv|--svg]
  #|Inspect a recorded ROS 2 LaserScan; SCAN_INDEX is zero-based, ignoring blank lines.
  #|Default: selected scan JSON, exact stamp and every original beam. CSV: long-form point table.
  #|SVG: equal-aspect sensor-frame return scatter. All input scans are validated first.
  #|Nonfinite ranges: quoted NaN, Infinity, +Infinity, -Infinity, or null. Bare NaN is invalid JSON.
  #|Offline only: no frame transform, motion correction, free-space inference or hardware action.

///|
fn run(args : Array[String]) -> Unit raise {
  if args.length() == 2 && (args[1] == "--help" || args[1] == "-h") {
    println(usage)
    return
  }
  guard args.length() == 4 ||
    (args.length() == 5 && (args[4] == "--csv" || args[4] == "--svg")) else {
    fail(usage)
  }
  let index = @string.parse_int(args[3]) catch {
    _ => fail("SCAN_INDEX must be a nonnegative integer")
  }
  if index < 0 {
    fail("SCAN_INDEX must be a nonnegative integer")
  }
  let text = @fsx.read_file_to_string(args[1]) catch {
    _ => fail("cannot read input JSONL")
  }
  let recording = match @telemetry.import_laser_scan_jsonl(text, args[2]) {
    Ok(v) => v
    Err(e) => fail(e)
  }
  guard recording.scans.get(index) is Some(scan) else {
    fail("SCAN_INDEX is outside the recording")
  }
  if args.length() == 5 {
    println(
      (if args[4] == "--csv" { scan.to_csv() } else { scan.to_svg() }).trim_end(),
    )
  } else {
    println(
      (
        {
          "input_file": args[1].to_json(),
          "format": recording.format.to_json(),
          "coordinates": recording.coordinates.to_json(),
          "timing": recording.timing.to_json(),
          "scan_index": index.to_json(),
          "scan_count": recording.scans.length().to_json(),
          "scan": scan.to_json(),
        } : Json).stringify(indent=2),
    )
  }
}

///|
fn main {
  run(@env.args()) catch {
    error => {
      println(({ "error": error.to_string() } : Json).stringify())
      @sys.exit(2)
    }
  }
}
