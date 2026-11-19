///|
extern "C" fn training_host_metric(index : Int32) -> Bytes = "moonrobo_training_host_metric"

///|
fn telemetry_host_text(
  read : (Int32) -> Bytes,
  index : Int32,
  name : String,
  errors : Map[String, String],
) -> String? {
  try {
    let bytes = read(index)
    guard bytes.length() > 0 && bytes.length() <= 16385 else {
      fail("invalid bounded host metric result")
    }
    let text = @utf8.decode(bytes[1:]).trim().to_owned()
    guard bytes[0] == b'\x00' else { fail(text) }
    Some(text)
  } catch {
    error => {
      errors[name] = error.to_string()[0:512].to_owned()
      None
    }
  }
}

///|
fn telemetry_host_snapshot(
  read~ : (Int32) -> Bytes = training_host_metric,
) -> Json {
  let errors : Map[String, String] = Map([])
  let available = match telemetry_host_text(read, 0, "/proc/meminfo", errors) {
    Some(text) =>
      Some(memory_available(text)) catch {
        error => {
          errors["/proc/meminfo"] = error.to_string()[0:512].to_owned()
          None
        }
      }
    None => None
  }
  let mut self_path : String? = None
  if telemetry_host_text(read, 1, "/proc/self/cgroup", errors) is Some(text) {
    for line in text.split("\n") {
      if line.has_prefix("0::") && line.length() <= 4099 {
        self_path = Some(line[3:].to_owned())
      }
    }
    if self_path is None {
      errors["/proc/self/cgroup"] = "unified cgroup path absent or exceeds 4096 characters"
    }
  }
  let metrics : Map[String, Json] = Map([])
  for
    i, name in [
      "memory.current", "memory.peak", "memory.max", "memory.events", "memory.swap.current",
      "memory.swap.max", "cpu.max",
    ] {
    let value = telemetry_host_text(
      read,
      i + 2,
      "/sys/fs/cgroup/" + name,
      errors,
    )
    metrics[name] = value.map(x => Json(x)).unwrap_or(Json::null())
  }
  {
    "host_mem_available_bytes": available
    .map(x => Json(x))
    .unwrap_or(Json::null()),
    "host_mem_available_source": "/proc/meminfo:MemAvailable",
    "cgroup_source": "/sys/fs/cgroup (visible mount root)",
    "process_unified_cgroup_path": self_path
    .map(x => Json(x))
    .unwrap_or(Json::null()),
    "mount_root_is_process_cgroup": self_path
    .map(x => Json(x == "/"))
    .unwrap_or(Json::null()),
    "ancestor_limits_enumerated": false,
    "cgroup_metrics": Json(metrics),
    "read_errors": Json(errors),
    "scope": "independent observations; root metrics are not all host ancestors; not added to allocator usage",
  }
}
