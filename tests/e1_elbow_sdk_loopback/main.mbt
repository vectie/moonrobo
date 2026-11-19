///|
/// Exercise the installed SDK with synthetic tracking in a private Linux
/// network namespace. Opening the vendor plugin may publish a mode message,
/// so verify isolation before loading it.
async fn main {
  guard @env.args()[1:] is [library, pose_file, reader_ready, report, .. rest] else {
    fail(
      "usage: e1_elbow_sdk_loopback SDK_PLUGIN SAMPLE_JSON READER_READY NEW_REPORT [close|idle|exit]",
    )
  }
  let ending = match rest {
    [] => "close"
    ["close"] => "close"
    ["idle"] => "idle"
    ["exit"] => "exit"
    _ => fail("unknown shutdown test")
  }
  let ifaces = @fs.read_file("/proc/net/dev")
    .text()
    .split("\n")
    .filter_map(line => line.find(":").map(i => line[:i].trim().to_owned()))
    .to_array()
  guard ifaces == ["lo"] else { fail("isolated loopback network required") }
  guard !@fs.exists(report) && !@fs.exists(reader_ready) else {
    fail("new report and new receiver readiness marker required")
  }
  let baseline : @elbow.Sample = @json.from_json(
    @fs.read_file(pose_file).json(),
  )
  let hold = baseline.stand_candidate()
  let clip = @elbow.Clip::gentle()
  let path = @elbow.Path::new(clip, hold[:])
  let controller = @low.Controller::open(library)
  let deadline = @env.now() + 15000UL
  while !@fs.exists(reader_ready) {
    guard @env.now() < deadline else { fail("DDS receiver not ready") }
    @async.sleep(5)
  }
  let mut previous = hold[@elbow.ELBOW_SLOT].position
  let start = @env.now().reinterpret_as_int64()
  for i in 0..<@elbow.FRAMES {
    let due = start + i.to_int64() * @elbow.DT_MS.to_int64()
    let delay = due - @env.now().reinterpret_as_int64()
    if delay > 0 {
      @async.sleep(delay.to_int())
    }
    let motors = baseline.motors.copy()
    motors[@elbow.ELBOW_SLOT] = {
      ..motors[@elbow.ELBOW_SLOT],
      position: previous,
    }
    let sample : @elbow.Sample = {
      motors,
      receipt_ms: due,
      source_ns: (i.to_int64() + 1L) * 20000000L,
    }
    let frame = path.next(sample, @env.now().reinterpret_as_int64())
    controller.publish(frame[:])
    previous = frame[@elbow.ELBOW_SLOT].position
  }
  let last_update = @env.now()
  // set_joint updates a cache. Allow one tick for the final wire sample.
  @async.sleep(@elbow.DT_MS)
  if ending == "idle" {
    @async.sleep(400)
    let accepted = try {
      controller.publish(hold[:])
      true
    } catch {
      _ => false
    }
    guard !accepted else {
      fail("expired command session accepted another target")
    }
  }
  if ending != "exit" {
    controller.close()
    controller.close()
  }
  let closed_at = @env.now()
  if ending == "close" {
    let accepted = try {
      controller.publish(hold[:])
      true
    } catch {
      _ => false
    }
    guard !accepted else { fail("closed handle accepted another target") }
    @async.sleep(400)
  }
  let result : Json = {
    "network": "isolated loopback",
    "status": "synthetic elbow tracking",
    "published_to_robot": false,
    "calls": Json(@elbow.FRAMES),
    "first_tick_host_ms": start.to_string(),
    "last_set_joint_host_ms": last_update.to_string(),
    "ending": ending,
    "close_returned_host_ms": if ending == "exit" {
      Json::null()
    } else {
      Json(closed_at.to_string())
    },
    "end_idle_host_ms": @env.now().to_string(),
  }
  @fs.write_file(report, result.stringify(indent=2), create_mode=CreateNew)
}
