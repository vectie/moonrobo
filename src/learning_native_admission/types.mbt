///|
/// Inputs for the explicit paper-capacity, stream-v2 path only. All sizes refer
/// to one rank. Pass validated artifact/metadata sizes, never a smaller estimate
/// obtained by extrapolating the N128 telemetry. Zero artifact sizes mean the
/// artifact is not inspected yet and select the fixed profile maxima.
pub(all) struct Inputs {
  profile : @capacity.CapacityProfile
  checkpoint_format : String
  environments : Int32
  replay_steps : Int32
  learner : @aligned.LearnerConfig
  observation_mode : @aligned.ObservationMode
  world_microbatch : Int32
  actor_microbatch : Int32
  sampler_bins : Int32
  // Original motion manifest, independently bounded at 256 MiB. This is not
  // the separately serialized checkpoint catalog (names/hashes), capped 64 MiB.
  motion_manifest_bytes : Int64
  catalog_json_bytes : Int64
  state_json_bytes : Int64
  environment_payload_bytes : Int64
  apic_manifest_bytes : Int64
  apic_payload_bytes : Int64
  apic_shared_union_bytes : Int64
  // Rows in the old runner and generation being prepared, respectively. Use
  // zero/zero with include_restore=false for a new run, and zero/saved_rows
  // with restore included for normal fresh-process resume. An empty saved
  // replay alone does not mean the optimizer archives need no restoration.
  restore_live_rows : Int32
  restore_saved_rows : Int32
  // Actual sum of three verified optimizer archive lengths for resume; zero
  // means unknown and uses the existing 3 * 512 MiB archive bound.
  restore_optimizer_archive_bytes : Int64
  distributed : Bool
}

///|
pub struct Phase {
  name : String
  components : Map[String, Int64]
  envelope_bytes : Int64
} derive(Debug, ToJson)

///|
pub extend Phase with @debug.Debug::{to_repr}

///|
pub extend Phase with ToJson::{to_json}

///|
/// Conservative estimate, not an observed or certified RSS/device peak. In
/// particular, allocator workspaces and SDK working memory are opaque. The
/// caller must retain its cgroup/no-swap watchdog and actual-memory admission.
pub struct Plan {
  format : String
  capacity_profile : String
  checkpoint_format : String
  restore_phases_included : Bool
  accounting_scope : String
  phases : Array[Phase]
  peak_bytes : Int64
  peak_phase : String
  // Baseline at the historical 65%; Decision carries the actual selected policy.
  required_remaining_bytes : Int64
  full_replacement_restore_peak_bytes : Int64
  full_replacement_restore_scope : String
  counts : Map[String, Int64]
  device_phase_working_bytes : Map[String, Int64]
  checkpoint_generation_bytes : Int64
  minimum_output_free_bytes : Int64
  assumptions : Array[String]
} derive(Debug, ToJson)

///|
pub extend Plan with @debug.Debug::{to_repr}

///|
pub extend Plan with ToJson::{to_json}

///|
pub struct Decision {
  format : String
  accepted : Bool
  host_remaining_bytes : Int64
  cuda_free_bytes : Int64
  limiting_remaining_bytes : Int64
  admission_percent : Int32
  minimum_free_reserve_bytes : Int64
  budget_bytes : Int64
  peak_bytes : Int64
  required_remaining_bytes : Int64
  baseline_65_percent_required_remaining_bytes : Int64
} derive(Debug, ToJson)

///|
pub extend Decision with @debug.Debug::{to_repr}

///|
pub extend Decision with ToJson::{to_json}
