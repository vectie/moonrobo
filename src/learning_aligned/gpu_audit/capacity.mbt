///|
struct AuditCapacity {
  worlds : Int32
  tape_bytes : Int64
  manifest_bytes : Int64
  payload_file_bytes : Int64
  payload_total_bytes : Int64
  numeric_union_bytes : Int64
  file_entries : Int32
  region_entries : Int32
}

///|
fn audit_capacity(profile : @capacity.CapacityProfile) -> AuditCapacity {
  let limits = profile.limits()
  {
    worlds: limits.max_environments,
    tape_bytes: limits.max_apic_oracle_bytes,
    manifest_bytes: limits.max_apic_manifest_bytes,
    payload_file_bytes: limits.max_apic_payload_file_bytes,
    payload_total_bytes: limits.max_apic_payload_total_bytes,
    numeric_union_bytes: limits.max_apic_numeric_union_bytes,
    // Initial audit historically permits 8192 entries. The explicit paper
    // profile uses its own fixed shared contract; no arbitrary config limits.
    file_entries: if profile == @capacity.Initial {
      8192
    } else {
      limits.max_apic_payload_files
    },
    region_entries: 8192,
  }
}

///|
fn requested_capacity(args : Array[String]) -> @capacity.CapacityProfile raise {
  let mut name : String? = None
  for i, arg in args {
    if arg == "--capacity-profile" {
      guard name is None && i + 1 < args.length() else {
        fail("--capacity-profile must appear once with initial or paper-4096")
      }
      name = Some(args[i + 1])
    }
  }
  @capacity.CapacityProfile::parse(name.unwrap_or("initial"))
}

///|
fn validate_manifest_capacity(
  manifest : Json,
  requested : @capacity.CapacityProfile,
) -> Unit raise {
  guard manifest is Object(fields) else {
    fail("audit manifest must be object")
  }
  let actual = match fields.get("capacity_profile") {
    None => @capacity.Initial
    Some(String(name)) => @capacity.CapacityProfile::parse(name)
    Some(_) => fail("manifest capacity_profile must be an exact profile string")
  }
  guard actual == requested else {
    fail("manifest capacity profile differs from explicit audit selection")
  }
}

///|
fn validate_selected_count(
  num_envs : Int32,
  profile : @capacity.CapacityProfile,
) -> Unit raise {
  guard num_envs >= 4 && num_envs <= audit_capacity(profile).worlds else {
    fail("v2 audit world count exceeds selected capacity profile")
  }
}

///|
fn audit_size_add(total : Int64, value : Int64, maximum : Int64) -> Int64 raise {
  guard total >= 0L &&
    value > 0L &&
    maximum > 0L &&
    total <= maximum &&
    value <= maximum - total else {
    fail("audit numeric/payload total exceeds capacity profile")
  }
  total + value
}

///|
fn require_json_headroom(bytes : Int64, available : Int64) -> Unit raise {
  guard bytes > 0L &&
    bytes <= 67108864L &&
    available > 0L &&
    // Preserve 65% even for bounded metadata construction/decoding. Integer
    // division before multiplication also avoids host-byte overflow.
    bytes * 16L <= available / 100L * 65L else {
    fail("audit metadata construction/decoding exceeds host/cgroup headroom")
  }
}
