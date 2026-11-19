///|
/// Explicit capacity selection, not memory admission or GPU authorization.
/// Missing configuration must be mapped to Initial by the caller.
pub(all) enum CapacityProfile {
  Initial
  Paper4096
} derive(Eq, Debug)

///|
pub extend CapacityProfile with Eq::{equal, not_equal}

///|
pub extend CapacityProfile with @debug.Debug::{to_repr}

///|
/// Read-only fixed bounds. Constructed only by CapacityProfile::limits; consumers
/// must not deserialize arbitrary limit records from configuration/checkpoints.
pub struct CapacityLimits {
  max_environments : Int32
  max_world_batch : Int32
  max_policy_batch : Int32
  max_replay_steps : Int32
  max_replay_values : Int64
  max_reference_frames : Int32
  max_tensor_values : Int64
  max_stream_total_bytes : Int64
  max_stream_member_bytes : Int64
  max_stream_members : Int32
  max_catalog_bytes : Int64
  max_state_bytes : Int64
  max_apic_numeric_union_bytes : Int64
  max_apic_payload_total_bytes : Int64
  max_apic_payload_file_bytes : Int64
  max_apic_payload_files : Int32
  max_apic_oracle_bytes : Int64
  max_apic_manifest_bytes : Int64
} derive(Eq, Debug, ToJson)

///|
pub extend CapacityLimits with Eq::{equal, not_equal}

///|
pub extend CapacityLimits with @debug.Debug::{to_repr}

///|
pub extend CapacityLimits with ToJson::{to_json}

///|
/// Accept exact stable identity names only; no whitespace/case/legacy aliases.
/// ```mbt check
/// test {
///   assert_eq(
///     @learning_native_capacity.CapacityProfile::parse("initial"),
///     @learning_native_capacity.Initial,
///   )
///   assert_eq(
///     @learning_native_capacity.CapacityProfile::parse("paper-4096").name(),
///     "paper-4096",
///   )
/// }
/// ```
pub fn CapacityProfile::parse(name : String) -> CapacityProfile raise {
  match name {
    "initial" => Initial
    "paper-4096" => Paper4096
    _ => fail("unknown native capacity profile; expected initial or paper-4096")
  }
}

///|
pub fn CapacityProfile::name(self : CapacityProfile) -> String {
  match self {
    Initial => "initial"
    Paper4096 => "paper-4096"
  }
}

///|
/// Paper4096 tensor values cover Observable102 with B4096, H32, history/preview10
/// and five critic permutations. This does not prove those buffers fit memory.
pub fn CapacityProfile::limits(self : CapacityProfile) -> CapacityLimits {
  match self {
    Initial =>
      {
        max_environments: 128,
        max_world_batch: 128,
        max_policy_batch: 128,
        max_replay_steps: 256,
        max_replay_values: 16777216L,
        max_reference_frames: 131072,
        max_tensor_values: 16777216L,
        max_stream_total_bytes: 536870912L,
        max_stream_member_bytes: 536870912L,
        max_stream_members: 64,
        max_catalog_bytes: 67108864L,
        max_state_bytes: 4194304L,
        max_apic_numeric_union_bytes: 536870912L,
        max_apic_payload_total_bytes: 1073741824L,
        max_apic_payload_file_bytes: 268435456L,
        max_apic_payload_files: 4096,
        max_apic_oracle_bytes: 4194304L,
        max_apic_manifest_bytes: 4194304L,
      }
    Paper4096 =>
      {
        max_environments: 4096,
        max_world_batch: 2048,
        max_policy_batch: 4096,
        max_replay_steps: 1000,
        max_replay_values: 958464000L,
        max_reference_frames: 135168,
        max_tensor_values: 127016960L,
        max_stream_total_bytes: 10737418240L,
        max_stream_member_bytes: 8589934592L,
        max_stream_members: 64,
        max_catalog_bytes: 67108864L,
        max_state_bytes: 4194304L,
        max_apic_numeric_union_bytes: 2147483648L,
        max_apic_payload_total_bytes: 4294967296L,
        max_apic_payload_file_bytes: 1073741824L,
        max_apic_payload_files: 4096,
        max_apic_oracle_bytes: 67108864L,
        max_apic_manifest_bytes: 67108864L,
      }
  }
}
