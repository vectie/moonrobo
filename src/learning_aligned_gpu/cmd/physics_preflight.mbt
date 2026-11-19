///|
struct PhysicsPreflight {
  manifest_sha256 : String
  bundle_bytes : Int64
  shared_region_bytes : Int64
  largest_file_bytes : Int64
  manifest_bytes : Int64
  manifest_identity : Json
} derive(ToJson)

///|
fn validate_physics_metadata(
  value : Json,
  s : Settings,
  config : Json,
) -> (Array[Json], Int64) raise {
  guard value
    is {
      "num_envs": count,
      "self_collisions": collisions,
      "control_dt_s": 0.02,
      "physics_dt_s": 0.005,
      "num_substeps": 4,
      "files": Array(files),
      "shared_regions": Array(regions),
      ..
    } else {
    fail(
      "APIC preflight requires fixed four-substep metadata and file/region inventories",
    )
  }
  let n : Int32 = @json.from_json(count)
  let collide : Bool = @json.from_json(collisions)
  let declared = @capacity.CapacityProfile::parse(
    setting(value, "capacity_profile", "initial"),
  )
  guard declared == s.capacity_profile else {
    fail("APIC artifact capacity profile differs from explicit learner profile")
  }
  let limits = s.capacity_profile.limits()
  let paper = s.capacity_profile == @capacity.Paper4096
  guard n == s.environments &&
    collide == setting(config, "self_collisions", true) &&
    setting(config, "physics_dt", 0.005) == 0.005 else {
    fail(
      "APIC world count, collision mode or physics dt differs from learner configuration",
    )
  }
  guard !files.is_empty() &&
    files.length() <= (if paper { limits.max_apic_payload_files } else { 8192 }) &&
    !regions.is_empty() &&
    regions.length() <= 8192 else {
    fail("APIC inventories exceed bounded native preflight")
  }
  let mut shared = 0L
  for region in regions {
    guard region is { "bytes": size, .. } else {
      fail("APIC region lacks byte size")
    }
    let bytes : Int32 = @json.from_json(size)
    guard bytes > 0 &&
      bytes.to_int64() <=
      (if paper { limits.max_apic_payload_file_bytes } else { 268435456L }) else {
      fail("APIC region exceeds explicit native capacity bound")
    }
    shared += bytes.to_int64()
    guard shared <=
      (if paper { limits.max_apic_numeric_union_bytes } else { 2147483648L }) else {
      fail("APIC shared union exceeds native 2 GiB bound")
    }
  }
  (files, shared)
}

///|
async fn bounded_physics_file(path : String, maximum : Int64) -> Int64 {
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  let size = file.size()
  guard size > 0L && size <= maximum else {
    fail("APIC input exceeds bounded native preflight: " + path)
  }
  size
}

///|
async fn physics_preflight(
  args : Array[String],
  config : Json,
  s : Settings,
) -> PhysicsPreflight? {
  if s.backend != "isaac" {
    return None
  }
  let path = required(args, "--physics-artifact")
  let adapter = required(args, "--physics-library")
  let limits = s.capacity_profile.limits()
  let paper = s.capacity_profile == @capacity.Paper4096
  let manifest_bytes = bounded_physics_file(
    path,
    limits.max_apic_manifest_bytes,
  )
  // A larger metadata cap is not permission to parse without host headroom.
  guard host_available() >= manifest_bytes * 16L + 1073741824L else {
    fail("insufficient host headroom to validate APIC manifest metadata")
  }
  ignore(bounded_physics_file(adapter, 268435456L))
  let digest = file_hash(path)
  let expected : String = setting(config, "physics_artifact_sha256", digest)
  if paper {
    guard config is Object(fields) &&
      fields.get("physics_artifact_sha256") is Some(String(pin)) &&
      valid_checkpoint_sha(pin) else {
      fail("paper-4096 requires an explicit pinned physics_artifact_sha256")
    }
  }
  guard digest == expected else {
    fail("APIC manifest differs from configured physics_artifact_sha256")
  }
  let (files, shared) = validate_physics_metadata(
    bounded_json(path, limits.max_apic_manifest_bytes),
    s,
    config,
  )
  let directory = dirname(path)
  let mut bundle = 0L
  let mut largest = 0L
  for file in files {
    guard file is { "path": String(relative), .. } &&
      !relative.has_prefix("/") &&
      relative.split("/").all(p => p != "" && p != "." && p != "..") else {
      fail("APIC inventory contains a non-relative path")
    }
    let bytes = bounded_physics_file(
      directory + "/" + relative,
      if paper {
        limits.max_apic_payload_file_bytes
      } else {
        268435456L
      },
    )
    bundle += bytes
    largest = largest.max(bytes)
    guard bundle <=
      (if paper { limits.max_apic_payload_total_bytes } else { 2147483648L }) else {
      fail("APIC bundle exceeds explicit native capacity bound")
    }
  }
  // The byte inventory is a measured lower bound, not a complete peak model:
  // driver/JIT/solver scratch is absent from the manifest. Keep the existing
  // 24 GiB scene reserve, 65% admission guard and external hard cgroup limit.
  let identity = @gpu_native.inspect_bundle(
    path,
    file_hash(required(args, "--scene")),
    self_collisions=setting(config, "self_collisions", true),
    expected_manifest_sha256=digest,
    adapter_library=adapter,
    capacity_profile=s.capacity_profile,
  )
  Some({
    manifest_sha256: digest,
    bundle_bytes: bundle,
    shared_region_bytes: shared,
    largest_file_bytes: largest,
    manifest_bytes,
    manifest_identity: identity,
  })
}
