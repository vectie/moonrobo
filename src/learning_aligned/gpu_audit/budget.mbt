///|
struct Budget {
  bundle_bytes : Int64
  shared_region_bytes : Int64
  largest_file_bytes : Int64
  projected_bytes : Int64
  host_available_bytes : Int64
  cuda_free_bytes : Int64
  host_cap_bytes : Int64
  device_cap_bytes : Int64
  estimate_only : Bool
} derive(ToJson)

///|
fn option(args : Array[String], name : String) -> String? raise {
  for i, arg in args {
    if arg == name {
      guard i + 1 < args.length() else { fail("missing value: " + name) }
      return Some(args[i + 1])
    }
  }
  None
}

///|
fn required(args : Array[String], name : String) -> String raise {
  guard option(args, name) is Some(value) else {
    fail("required option: " + name)
  }
  value
}

///|
async fn file_size(path : String, maximum : Int64) -> Int64 {
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  let size = file.size()
  guard size > 0L && size <= maximum else {
    fail("audit file size exceeds bound: " + path)
  }
  size
}

///|
async fn read_json(path : String, maximum : Int64) -> Json {
  let (value, _) = read_json_hashed(path, maximum)
  value
}

///|
async fn read_json_hashed(path : String, maximum : Int64) -> (Json, String) {
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  let size = file.size()
  guard size > 0L && size <= maximum && size <= 67108864L else {
    fail("audit metadata exceeds bounded JSON size: " + path)
  }
  if size > 4194304L {
    require_json_headroom(size, host_available())
  }
  let bytes = file.read_exactly_at(size.to_int(), position=0L)
  guard file.size() == size else { fail("audit metadata changed during read") }
  let hash = @crypto.SHA256::new()
  hash.update(bytes)
  (
    @json.parse(@utf8.decode(bytes)),
    @crypto.bytes_to_hex_string(hash.finalize()),
  )
}

///|
async fn hash_file(path : String, maximum : Int64) -> String {
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  let size = file.size()
  guard size > 0L && size <= maximum else {
    fail("audit hash file exceeds bound: " + path)
  }
  let hash = @crypto.SHA256::new()
  for offset = 0L; offset < size; {
    let n = (size - offset).min(65536L).to_int()
    hash.update(file.read_exactly_at(n, position=offset))
    continue offset + n.to_int64()
  }
  guard file.size() == size else { fail("audit file changed during hash") }
  @crypto.bytes_to_hex_string(hash.finalize())
}

///|
// The authoring ABI emits shared_regions[].bytes as JSON numbers, while
// MoonBit Int64 JSON serialization uses decimal strings. Accept both without
// rounding a fractional number or converting before checking its bound.
fn audit_region_bytes(value : Json, maximum : Int64) -> Int64 raise {
  guard maximum > 0L && maximum <= 9007199254740991L else {
    fail("invalid exact audit region byte bound")
  }
  let bytes = match value {
    Number(number) => {
      guard finite(number) && number > 0.0 && number <= maximum.to_double() else {
        fail("audit shared region exceeds profile member bound")
      }
      let exact = number.to_int64()
      guard exact.to_double() == number else {
        fail("audit shared region bytes must be an exact integer")
      }
      exact
    }
    String(text) => {
      guard !text.is_empty() && text.iter().all(c => c >= '0' && c <= '9') else {
        fail("audit shared region bytes must be decimal integer digits")
      }
      @string.parse_int64(text)
    }
    _ => fail("audit shared region bytes must be an integer number or string")
  }
  guard bytes > 0L && bytes <= maximum else {
    fail("audit shared region exceeds profile member bound")
  }
  bytes
}

///|
fn audit_shared_region_bytes(
  regions : Array[Json],
  capacity : AuditCapacity,
) -> Int64 raise {
  let mut shared = 0L
  for region in regions {
    guard region is { "bytes": bytes, .. } else {
      fail("invalid shared region")
    }
    let n = audit_region_bytes(bytes, capacity.payload_file_bytes)
    shared = audit_size_add(shared, n, capacity.numeric_union_bytes)
  }
  shared
}

///|
async fn preflight(
  args : Array[String],
  num_envs : Int32,
  capacity_profile : @capacity.CapacityProfile,
) -> Budget {
  let capacity = audit_capacity(capacity_profile)
  let manifest_path = required(args, "--manifest")
  let manifest = read_json(manifest_path, capacity.manifest_bytes)
  validate_manifest_capacity(manifest, capacity_profile)
  guard manifest
    is {
      "num_envs": actual_worlds,
      "files": Array(files),
      "shared_regions": Array(regions),
      ..
    } &&
    actual_worlds == Json(num_envs) &&
    num_envs >= 2 &&
    num_envs <= capacity.worlds &&
    files.length() > 0 &&
    files.length() <= capacity.file_entries &&
    regions.length() > 0 &&
    regions.length() <= capacity.region_entries else {
    fail(
      "bounded replay audit requires matching profile worlds and bounded file/region inventories",
    )
  }
  let parts = manifest_path.split("/").to_array()
  let directory = if parts.length() > 1 {
    parts[0:parts.length() - 1].join("/") + "/"
  } else {
    ""
  }
  let mut bundle = 0L
  let mut largest = 0L
  for file in files {
    guard file is { "path": String(path), .. } &&
      !path.has_prefix("/") &&
      path
      .split("/")
      .all(segment => segment != ".." && segment != "." && segment != "") else {
      fail("invalid bounded bundle path")
    }
    let size = file_size(directory + path, capacity.payload_file_bytes)
    bundle = audit_size_add(bundle, size, capacity.payload_total_bytes)
    largest = largest.max(size)
  }
  let shared = audit_shared_region_bytes(regions, capacity)
  let host_mib = @string.parse_int64(
    option(args, "--max-host-mib").unwrap_or("8192"),
  )
  let device_mib = @string.parse_int64(
    option(args, "--max-device-mib").unwrap_or("8192"),
  )
  guard host_mib >= 2048L &&
    host_mib <= 16384L &&
    device_mib >= 2048L &&
    device_mib <= 16384L else {
    fail("audit host/device limits must be within 2048..16384 MiB")
  }
  // Four independent graphs, primitive union copies, loader buffers and a
  // conservative scratch allowance. Internal vendor scratch has no hard bound
  // in this manifest: retain external cgroup and watchdog limits as well.
  let projected = shared * 8L + bundle * 2L + largest * 2L + 1073741824L
  let host = host_available()
  let host_cap = host_mib * 1048576L
  let device_cap = device_mib * 1048576L
  guard projected <= host_cap &&
    projected <= device_cap &&
    projected <= host * 65L / 100L else {
    fail("APIC replay audit exceeds host/device planned budget before CUDA")
  }
  let cuda = @gpu.audit_device_free_bytes(
    required(args, "--adapter"),
    device_id=@string.parse_int(option(args, "--device").unwrap_or("0")),
  )
  guard projected <= cuda * 65L / 100L else {
    fail("APIC replay audit exceeds current CUDA free-memory budget")
  }
  {
    bundle_bytes: bundle,
    shared_region_bytes: shared,
    largest_file_bytes: largest,
    projected_bytes: projected,
    host_available_bytes: host,
    cuda_free_bytes: cuda,
    host_cap_bytes: host_cap,
    device_cap_bytes: device_cap,
    estimate_only: true,
  }
}
