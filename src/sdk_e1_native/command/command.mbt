///|
fn parent(path : String) -> String {
  let parts = path.split("/").to_array()
  let dirs : Array[String] = []
  for i in 0..<(parts.length() - 1) {
    dirs.push(parts[i].to_owned())
  }
  let result = dirs.join("/")
  if result == "" {
    "."
  } else {
    result
  }
}

///|
async fn emit(snapshot : @sdk.SdkE1Snapshot, output : String) -> Unit {
  let text = @sdk.snapshot_json(snapshot, indent=0) + "\n"
  if output == "" {
    println(text.trim().to_owned())
  } else {
    let directory = parent(output)
    if !@fs.exists(directory) {
      @fs.mkdir(directory, recursive=true)
    }
    let temporary = output + ".tmp"
    @fs.write_file(temporary, text, create_mode=CreateOrTruncate)
    @fs.rename(temporary, output, replace=true)
  }
}

///|
async fn signature(path : String) -> (Int64, Int64) {
  let (seconds, nanos) = @fs.mtime(path)
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  (seconds * 1000000000L + nanos.to_int64(), file.size())
}

///|
pub async fn run(args : Array[String]) -> Unit {
  guard args.length() >= 2 else {
    fail(
      "usage: moonrobo-sdk-e1-native read|write [bridge flags] [--library SDK_ADAPTER]",
    )
  }
  let mode = args[1]
  let flags : Map[String, Bool] = {}
  let options : Map[String, String] = {}
  let mut i = 2
  while i < args.length() {
    let key = args[i]
    if [
        "--live", "--once", "--self-check", "--repeat-frame-id", "--dry-run", "--watch",
      ].contains(key) {
      flags[key] = true
      i += 1
    } else {
      if i + 1 >= args.length() {
        fail("missing value for " + key)
      }
      options[key] = args[i + 1]
      i += 2
    }
  }
  let sdk_root = options.get("--sdk-root").unwrap_or("../sdk")
  let library = options
    .get("--library")
    .unwrap_or(sdk_root + "/build/libmoonrobo_e1.so")
  let needs_live = !flags.contains("--self-check") &&
    (
      (mode == "read" && flags.contains("--live")) ||
      (mode == "write" && !flags.contains("--dry-run"))
    )
  if needs_live && @env.get_env_var("CYCLONEDDS_URI") is None {
    @env.set_env_var(
      "CYCLONEDDS_URI",
      "file://" + @fs.realpath(sdk_root) + "/config/dds.xml",
    )
  }
  match mode {
    "read" => {
      if flags.contains("--self-check") {
        let errors = @bridge.validate_snapshot_shape(
          @bridge.fixture_snapshot("self-check", 0L),
        )
        if !errors.is_empty() {
          fail(errors.join("; "))
        }
        println("ok")
        return
      }
      let live = flags.contains("--live")
      let controller = if live {
        Some(@bridge.Controller::open(library))
      } else {
        None
      }
      let once = flags.contains("--once") || !live
      let base = options.get("--frame-id").unwrap_or("sdk-e1-sidecar-frame")
      let interval = @string.parse_int(
        options.get("--interval-ms").unwrap_or("100"),
      )
      let explicit = options
        .get("--captured-at-ms")
        .map(text => @string.parse_int64(text))
      let mut sequence = 0
      for ;; {
        let captured = explicit.unwrap_or(@env.now().to_int64())
        let frame = @bridge.frame_id_for(
          base,
          sequence,
          flags.contains("--repeat-frame-id"),
          once,
        )
        let snapshot = match controller {
          Some(c) => c.snapshot(frame, captured)
          None => @bridge.fixture_snapshot(frame, captured)
        }
        emit(snapshot, options.get("--output").unwrap_or(""))
        if once {
          break
        }
        sequence += 1
        @async.sleep(if interval < 1 { 1 } else { interval })
      }
    }
    "write" => {
      if flags.contains("--self-check") {
        let errors = @bridge.validate_command(@bridge.fixture_command())
        if !errors.is_empty() {
          fail(errors.join("; "))
        }
        println("ok")
        return
      }
      guard options.get("--input") is Some(input) && input != "" else {
        fail("--input is required")
      }
      let dry = flags.contains("--dry-run")
      let controller = if dry {
        None
      } else {
        Some(@bridge.Controller::open(library))
      }
      let watch = flags.contains("--watch")
      let initial = if watch && @fs.exists(input) {
        Some(signature(input))
      } else {
        None
      }
      let state = @bridge.WatchState::new(watch, initial)
      let poll = @string.parse_int(options.get("--poll-ms").unwrap_or("50"))
      for ;; {
        if @fs.exists(input) {
          let current = signature(input)
          if state.changed(current) {
            let command = @bridge.load_command(@fs.read_file(input).text())
            let result = match controller {
              Some(c) => c.publish(command)
              None => @bridge.dry_run(command)
            }
            println(result.stringify())
            state.acknowledge(current)
          }
        }
        if !watch {
          break
        }
        @async.sleep(if poll < 1 { 1 } else { poll })
      }
    }
    _ => fail("expected read or write")
  }
}
