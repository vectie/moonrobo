///|
/// Match the existing CLI admission caps. These limits bound validation work,
/// not CUDA peak allocation; the independent 24 GiB reserve is still required.
const BundleMetadataLimit : Int64 = 4194304L

///|
const BundleFileLimit : Int64 = 268435456L

///|
const BundleTotalLimit : Int64 = 2147483648L

///|
struct BundleLimits {
  metadata : Int64
  member : Int64
  total : Int64
  union_bytes : Int64
  files : Int32
  regions : Int32
  environments : Int32
}

///|
// Initial consumer historically accepts a larger inventory than the producer.
// Preserve those byte/count limits; Paper must be independently opted into.
fn bundle_limits(profile : @capacity.CapacityProfile) -> BundleLimits {
  let shared = profile.limits()
  match profile {
    Initial =>
      {
        metadata: BundleMetadataLimit,
        member: BundleFileLimit,
        total: BundleTotalLimit,
        union_bytes: BundleTotalLimit,
        files: 8192,
        regions: 8192,
        environments: shared.max_environments,
      }
    Paper4096 =>
      {
        metadata: shared.max_apic_manifest_bytes,
        member: shared.max_apic_payload_file_bytes,
        total: shared.max_apic_payload_total_bytes,
        union_bytes: shared.max_apic_numeric_union_bytes,
        files: shared.max_apic_payload_files,
        regions: 8192,
        environments: shared.max_environments,
      }
  }
}

///|
struct BundleFileIdentity {
  path : String
  bytes : Int64
  modified : (Int64, Int32)
  changed : (Int64, Int32)
}

///|
struct VerifiedBundle {
  manifest : Manifest
  digest : String
  directory : String
  identities : Array[BundleFileIdentity]
  resources : Json
}

///|
fn bundle_sha256(value : String) -> Bool {
  value.length() == 64 &&
  value.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
}

///|
fn bounded_bundle_size(
  bytes : Int64,
  limit : Int64,
  path : String,
) -> Unit raise {
  guard bytes > 0L && bytes <= limit else {
    fail("APIC file size outside 1..\{limit} bytes: \{path} (\{bytes})")
  }
}

///|
fn add_bundle_bytes(
  total : Int64,
  bytes : Int64,
  capacity_profile~ : @capacity.CapacityProfile = Initial,
  union~ : Bool = false,
) -> Int64 raise {
  let limits = bundle_limits(capacity_profile)
  let maximum = if union { limits.union_bytes } else { limits.total }
  bounded_bundle_size(bytes, limits.member, "bundle inventory member")
  guard total >= 0L && bytes <= maximum && total <= maximum - bytes else {
    fail("APIC bundle inventory exceeds profile " + capacity_profile.name())
  }
  total + bytes
}

///|
/// Canonicalize the directory, but require the final file itself to be regular.
/// Payload resolution below additionally rejects symlinked directory components.
async fn canonical_bundle_file(path : String) -> String {
  guard !path.is_empty() &&
    !path.contains("\u{0}") &&
    @utf8.encode(path).length() <= 4096 else {
    fail("invalid APIC file path")
  }
  guard @fs.kind(path, follow_symlink=false) is Regular else {
    fail("APIC input must be a regular file, not a symlink: " + path)
  }
  let canonical = @fs.realpath(path)
  guard @fs.kind(canonical, follow_symlink=false) is Regular else {
    fail("APIC input changed while resolving its path: " + path)
  }
  canonical
}

///|
async fn bundle_payload_path(directory : String, relative : String) -> String {
  guard relative_path(relative) else { fail("unsafe APIC payload path") }
  let parts = relative.split("/").to_array()
  let mut path = directory
  for i, part in parts {
    path += "/" + part.to_string()
    let kind = @fs.kind(path, follow_symlink=false)
    if i + 1 == parts.length() {
      guard kind is Regular else {
        fail("APIC payload must be a regular file: " + relative)
      }
    } else {
      guard kind is Directory else {
        fail("APIC payload directory must not be a symlink: " + relative)
      }
    }
  }
  guard @fs.realpath(path) == path else {
    fail("APIC payload escapes its canonical bundle directory: " + relative)
  }
  path
}

///|
async fn bundle_file_identity(
  path : String,
  limit : Int64,
) -> BundleFileIdentity {
  guard @fs.kind(path, follow_symlink=false) is Regular &&
    @fs.realpath(path) == path else {
    fail("APIC input path is no longer a canonical regular file: " + path)
  }
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  guard file.kind() is Regular else { fail("APIC input is not a regular file") }
  let bytes = file.size()
  bounded_bundle_size(bytes, limit, path)
  { path, bytes, modified: file.mtime(), changed: file.ctime(), }
}

///|
async fn assert_bundle_identity(identity : BundleFileIdentity) -> Unit {
  let actual = bundle_file_identity(identity.path, identity.bytes)
  guard actual.bytes == identity.bytes &&
    actual.modified == identity.modified &&
    actual.changed == identity.changed else {
    fail("APIC input changed during validation/loading: " + identity.path)
  }
}

///|
async fn check_open_bundle_file(
  file : @fs.File,
  identity : BundleFileIdentity,
) -> Unit {
  guard file.kind() is Regular &&
    file.size() == identity.bytes &&
    file.mtime() == identity.modified &&
    file.ctime() == identity.changed else {
    fail("APIC file changed before/while hashing: " + identity.path)
  }
}

///|
async fn hash_bundle_file(identity : BundleFileIdentity) -> String {
  assert_bundle_identity(identity)
  let file = @fs.open(identity.path, mode=ReadOnly)
  defer file.close()
  check_open_bundle_file(file, identity)
  let hash = @crypto.SHA256::new()
  for offset = 0L; offset < identity.bytes; {
    let n = (identity.bytes - offset).min(65536L).to_int()
    hash.update(file.read_exactly_at(n, position=offset))
    continue offset + n.to_int64()
  }
  check_open_bundle_file(file, identity)
  assert_bundle_identity(identity)
  @crypto.bytes_to_hex_string(hash.finalize())
}

///|
async fn bounded_bundle_manifest(
  path : String,
  capacity_profile~ : @capacity.CapacityProfile = Initial,
) -> (BundleFileIdentity, Bytes) {
  let identity = bundle_file_identity(
    canonical_bundle_file(path),
    bundle_limits(capacity_profile).metadata,
  )
  let file = @fs.open(identity.path, mode=ReadOnly)
  defer file.close()
  check_open_bundle_file(file, identity)
  let bytes = file.read_exactly_at(identity.bytes.to_int(), position=0L)
  check_open_bundle_file(file, identity)
  assert_bundle_identity(identity)
  (identity, bytes)
}

///|
async fn validated_adapter(path : String) -> (BundleFileIdentity, String) {
  let identity = bundle_file_identity(
    canonical_bundle_file(path),
    BundleFileLimit,
  )
  (identity, hash_bundle_file(identity))
}

///|
async fn VerifiedBundle::assert_unchanged(self : VerifiedBundle) -> Unit {
  for identity in self.identities {
    assert_bundle_identity(identity)
  }
}
