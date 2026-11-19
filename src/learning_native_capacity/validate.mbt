///|
fn checked_add(a : Int64, b : Int64) -> Int64 raise {
  guard a >= 0L && b >= 0L && a <= 9223372036854775807L - b else {
    fail("native capacity sum is negative or overflows Int64")
  }
  a + b
}

///|
fn checked_mul(a : Int64, b : Int64) -> Int64 raise {
  guard a >= 0L && b >= 0L && (b == 0L || a <= 9223372036854775807L / b) else {
    fail("native capacity product is negative or overflows Int64")
  }
  a * b
}

///|
/// Exact logical replay payload; excludes slab headers, live allocation growth,
/// transient batches, checkpoint restoration copies and allocator overhead/RSS.
pub struct ReplayCapacity {
  records : Int64
  values : Int64
  float64_bytes : Int64
  indices_bytes : Int64
  flags_bytes : Int64
  payload_bytes : Int64
} derive(Eq, Debug, ToJson)

///|
pub extend ReplayCapacity with Eq::{equal, not_equal}

///|
pub extend ReplayCapacity with @debug.Debug::{to_repr}

///|
pub extend ReplayCapacity with ToJson::{to_json}

///|
/// Validate positive dimensions against the selected fixed profile and compute
/// the unchanged 234-F64 + two-I32 + two-U8 replay layout without allocating it.
pub fn CapacityProfile::validate_dimensions(
  self : CapacityProfile,
  environments~ : Int32,
  world_batch~ : Int32,
  policy_batch~ : Int32,
  replay_steps~ : Int32,
) -> ReplayCapacity raise {
  let limits = self.limits()
  guard environments > 0 &&
    environments <= limits.max_environments &&
    world_batch > 0 &&
    world_batch <= limits.max_world_batch &&
    policy_batch > 0 &&
    policy_batch <= limits.max_policy_batch &&
    replay_steps > 0 &&
    replay_steps <= limits.max_replay_steps else {
    fail("native dimensions exceed capacity profile " + self.name())
  }
  let records = checked_mul(environments.to_int64(), replay_steps.to_int64())
  let values = checked_mul(records, 234L)
  // Preserve the current Int32 logical-index contract as well as profile caps.
  guard values <= limits.max_replay_values && values <= 2147483647L else {
    fail("native replay value count exceeds profile or indexing bound")
  }
  let float64_bytes = checked_mul(values, 8L)
  let indices_bytes = checked_mul(records, 8L)
  let flags_bytes = checked_mul(records, 2L)
  {
    records,
    values,
    float64_bytes,
    indices_bytes,
    flags_bytes,
    payload_bytes: checked_add(
      checked_add(float64_bytes, indices_bytes),
      flags_bytes,
    ),
  }
}

///|
/// Catalog JSON keeps its independent decode limit in both profiles. Include
/// these bytes exactly once in the sidecars passed to validate_stream_totals.
pub fn CapacityProfile::validate_catalog_bytes(
  self : CapacityProfile,
  bytes : Int64,
) -> Unit raise {
  guard bytes > 0L && bytes <= self.limits().max_catalog_bytes else {
    fail("native catalog must be positive and at most 64 MiB")
  }
}

///|
/// Sum all stream-v2 sidecar lengths (numeric blobs AND catalog.json) plus
/// state.json once. Zero-length numeric blobs are legal; metadata must be
/// positive. Optimizer archives and receipt.json are outside this payload cap
/// and still require their existing separate limits and memory admission.
/// Filename, dtype, shape, SHA and required-member checks remain caller duties.
pub fn CapacityProfile::validate_stream_totals(
  self : CapacityProfile,
  sidecar_bytes : ArrayView[Int64],
  state_bytes~ : Int64,
) -> Int64 raise {
  let limits = self.limits()
  guard !sidecar_bytes.is_empty() &&
    sidecar_bytes.length() <= limits.max_stream_members &&
    state_bytes > 0L &&
    state_bytes <= limits.max_state_bytes else {
    fail("native stream metadata size or sidecar count exceeds fixed profile")
  }
  let mut total = state_bytes
  for bytes in sidecar_bytes {
    guard bytes >= 0L && bytes <= limits.max_stream_member_bytes else {
      fail("native stream sidecar exceeds capacity profile " + self.name())
    }
    total = checked_add(total, bytes)
    guard total <= limits.max_stream_total_bytes else {
      fail("native stream payload exceeds capacity profile " + self.name())
    }
  }
  total
}
