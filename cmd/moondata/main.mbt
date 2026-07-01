///|
struct MoonDataCliSummary {
  root : String
  dataset_path : String
  episode_path : String
  quality_path : String
  status : String
  finding_count : Int
} derive(ToJson)

///|
fn cli_arg(args : Array[String], index : Int) -> String? {
  if index < args.length() {
    Some(args[index])
  } else {
    None
  }
}

///|
fn parse_ms(value : String, fallback : Int64) -> Int64 {
  (@string.parse_int(value) catch { _ => return fallback }).to_int64()
}

///|
fn now_ms() -> Int64 {
  @env.now().reinterpret_as_int64()
}

///|
fn print_usage() -> Unit {
  println("moon run cmd/moondata --target native -- init [moondata-root]")
  println(
    "moon run cmd/moondata --target native -- register-sample [moondata-root] [robot-id] [bridge-id] [now-ms]",
  )
}

///|
fn print_store_error(error : @moondata_store.MoonDataStoreIssue) -> Unit {
  println(
    "MoonData store failed [\{error.code}] \{error.path}: \{error.message}",
  )
}

///|
fn init_root(root : String) -> Unit {
  match @moondata_store.initialize_root(root) {
    Ok(result) => println(result.to_json().stringify(indent=2))
    Err(error) => print_store_error(error)
  }
}

///|
fn sample_registration(
  robot_id : String,
  bridge_id : String,
  now : Int64,
) -> @moondata_ingest.CaptureRegistration {
  let capture_id = "cap-\{robot_id}-\{now}"
  let episode_id = "ep-\{robot_id}-\{now}"
  let request : @moondata_ingest.CaptureRegistrationRequest = {
    source_id: "src-\{robot_id}-moondata-sample",
    capture_id,
    dataset_id: "ds-\{robot_id}-sample",
    episode_id,
    robot_id,
    bridge_id,
    session_id: "session-\{robot_id}-\{now}",
    source_kind: "moondata-sample",
    source_label: "MoonData sample capture",
    origin_uri: "moondata://sample/\{robot_id}/\{now}",
    status: "stopped",
    started_at_ms: now,
    stopped_at_ms: Some(now + 20L),
    receipt_ids: ["receipt-\{capture_id}"],
    frames: [
      @moondata_ingest.frame_input(
        "frame-\{robot_id}-0001",
        now,
        "moondata://sample/\{robot_id}/frame-0001.json",
        byte_count=64L,
      ),
      @moondata_ingest.frame_input(
        "frame-\{robot_id}-0002",
        now + 20L,
        "moondata://sample/\{robot_id}/frame-0002.json",
        byte_count=64L,
      ),
    ],
  }
  @moondata_ingest.register_capture(request)
}

///|
fn write_frame_manifests(
  root : String,
  frames : Array[@moondata_core.FrameRef],
) -> Bool {
  for frame in frames {
    match @moondata_store.write_frame(root, frame) {
      Ok(_) => ()
      Err(error) => {
        print_store_error(error)
        return false
      }
    }
  }
  true
}

///|
fn register_sample(
  root : String,
  robot_id : String,
  bridge_id : String,
  now : Int64,
) -> Unit {
  match @moondata_store.initialize_root(root) {
    Err(error) => {
      print_store_error(error)
      return
    }
    Ok(_) => ()
  }
  let registration = sample_registration(robot_id, bridge_id, now)
  let quality = @moondata_quality.evaluate_episode(
    "qr-\{registration.episode.episode_id}",
    registration.dataset.dataset_id,
    registration.episode,
    registration.frames,
    now,
    config=@moondata_quality.default_quality_config(
      expected_robot_id=robot_id,
      expected_bridge_id=bridge_id,
    ),
  )
  match @moondata_store.write_source(root, registration.source) {
    Err(error) => {
      print_store_error(error)
      return
    }
    Ok(_) => ()
  }
  match @moondata_store.write_capture(root, registration.capture) {
    Err(error) => {
      print_store_error(error)
      return
    }
    Ok(_) => ()
  }
  match @moondata_store.write_dataset(root, registration.dataset) {
    Err(error) => {
      print_store_error(error)
      return
    }
    Ok(dataset_persisted) =>
      match @moondata_store.write_episode(root, registration.episode) {
        Err(error) => {
          print_store_error(error)
          return
        }
        Ok(episode_persisted) => {
          if !write_frame_manifests(root, registration.frames) {
            return
          }
          match @moondata_store.write_quality_run(root, quality) {
            Err(error) => print_store_error(error)
            Ok(quality_persisted) =>
              println(
                {
                  root,
                  dataset_path: dataset_persisted.path,
                  episode_path: episode_persisted.path,
                  quality_path: quality_persisted.path,
                  status: quality.status,
                  finding_count: quality.finding_count,
                }
                .to_json()
                .stringify(indent=2),
              )
          }
        }
      }
  }
}

///|
fn main {
  let args = @sys.get_cli_args()
  let command = cli_arg(args, 1).unwrap_or("help")
  let root = cli_arg(args, 2).unwrap_or("moondata")
  match command {
    "init" => init_root(root)
    "register-sample" => {
      let robot_id = cli_arg(args, 3).unwrap_or("noetix-e1-lab-01")
      let bridge_id = cli_arg(args, 4).unwrap_or("sdk-e1")
      let now = parse_ms(cli_arg(args, 5).unwrap_or(""), now_ms())
      register_sample(root, robot_id, bridge_id, now)
    }
    "help" => print_usage()
    _ => {
      println("unknown MoonData command: \{command}")
      print_usage()
    }
  }
}
