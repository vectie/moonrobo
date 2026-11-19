///|
pub fn memory_available(text : String) -> Int64 raise {
  for line in text.split("\n") {
    if line.has_prefix("MemAvailable:") {
      let parts = line.split(" ").filter(x => !x.is_empty()).to_array()
      guard parts.length() >= 3 && parts[2] == "kB" else {
        fail("invalid Linux MemAvailable units")
      }
      let kb = @string.parse_int64(parts[1])
      guard kb > 0L && kb < 9007199254740L else {
        fail("invalid Linux MemAvailable")
      }
      return kb * 1024L
    }
  }
  fail("Linux MemAvailable unavailable; refusing unknown memory budget")
}

///|
pub async fn constrain_cgroup(
  available : Int64,
  root : String,
  v2 : Bool,
) -> Int64 {
  let limit_path = root +
    (if v2 { "/memory.max" } else { "/memory.limit_in_bytes" })
  let used_path = root +
    (if v2 { "/memory.current" } else { "/memory.usage_in_bytes" })
  if !@fs.exists(limit_path) || !@fs.exists(used_path) {
    return available
  }
  let raw = @utf8.decode(@fs.read_file(limit_path).binary()).trim_space()
  if raw == "max" {
    return available
  }
  let limit = @string.parse_int64(raw)
  if limit >= 1152921504606846976L {
    return available
  }
  let used = @string.parse_int64(
    @utf8.decode(@fs.read_file(used_path).binary()).trim_space(),
  )
  available.min((limit - used).max(0L))
}

///|
pub async fn host_available() -> Int64 {
  guard @fs.exists("/proc/meminfo") else {
    fail(
      "native training memory guard requires Linux /proc/meminfo; host budget is unknown",
    )
  }
  let mut available = memory_available(
    @utf8.decode(@fs.read_file("/proc/meminfo").binary()),
  )
  available = constrain_cgroup(available, "/sys/fs/cgroup", true)
  available = constrain_cgroup(available, "/sys/fs/cgroup/memory", false)
  // On a host, the process can be inside a systemd/user cgroup. Account for every
  // visible ancestor; inside a container the root paths above remain authoritative.
  if @fs.exists("/proc/self/cgroup") {
    let groups = @utf8.decode(@fs.read_file("/proc/self/cgroup").binary())
    for line in groups.split("\n") {
      let parts = line.split(":").to_array()
      if parts.length() != 3 {
        continue
      }
      let v2 = parts[1] == ""
      if !v2 && !parts[1].split(",").any(x => x == "memory") {
        continue
      }
      let mut path = if v2 { "/sys/fs/cgroup" } else { "/sys/fs/cgroup/memory" }
      for segment in parts[2].split("/") {
        if segment == "" {
          continue
        }
        guard segment != "." && segment != ".." else {
          fail("unexpected cgroup path")
        }
        path += "/" + segment.to_owned()
        available = constrain_cgroup(available, path, v2)
      }
    }
  }
  guard available > 0L else { fail("host/cgroup memory exhausted") }
  available
}
