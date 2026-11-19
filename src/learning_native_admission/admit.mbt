///|
/// Compare the combined per-rank phase envelope with actual host/cgroup and
/// CUDA free memory. Absence preserves exactly the original 65% budget. An
/// explicit percent (65..80) also retains at least 16 GiB after the envelope.
/// Zero/unknown availability fails; this performs no allocation or device I/O.
pub fn assess(
  plan : Plan,
  host_remaining_bytes : Int64,
  cuda_free_bytes : Int64,
  memory_admission_percent? : Int32,
) -> Decision raise {
  guard host_remaining_bytes > 0L && cuda_free_bytes > 0L else {
    fail(
      "native paper admission requires positive actual host and CUDA free bytes",
    )
  }
  let percent = memory_admission_percent.unwrap_or(65)
  guard percent >= 65 && percent <= 80 else {
    fail("paper memory_admission_percent must be within 65..80")
  }
  let reserve = if memory_admission_percent is Some(_) { 16L * GiB } else { 0L }
  let remaining = host_remaining_bytes.min(cuda_free_bytes)
  // Divide before multiplying to keep even Int64.max memory observations safe.
  let budget = add(
    mul(remaining / 100L, percent.to_int64()),
    mul(remaining % 100L, percent.to_int64()) / 100L,
  ).min((remaining - reserve).max(0L))
  let required = ceil_div(mul(plan.peak_bytes, 100L), percent.to_int64()).max(
    add(plan.peak_bytes, reserve),
  )
  {
    format: "moonrobo.native-paper-memory-decision.v1",
    accepted: plan.peak_bytes <= budget,
    host_remaining_bytes,
    cuda_free_bytes,
    limiting_remaining_bytes: remaining,
    admission_percent: percent,
    minimum_free_reserve_bytes: reserve,
    budget_bytes: budget,
    peak_bytes: plan.peak_bytes,
    required_remaining_bytes: required,
    baseline_65_percent_required_remaining_bytes: plan.required_remaining_bytes,
  }
}

///|
pub fn Decision::require_accepted(self : Decision) -> Unit raise {
  guard self.accepted else {
    fail(
      "native paper memory admission refused: phase envelope exceeds selected " +
      self.admission_percent.to_string() +
      "% budget or minimum free reserve " +
      self.minimum_free_reserve_bytes.to_string() +
      " bytes",
    )
  }
}

///|
/// Free bytes must be read on the output filesystem (statvfs/f_bavail), after
/// accounting for any other concurrent writer. Existing generations are already
/// used space; they are not deleted or counted as available. Recheck immediately
/// before creating a fresh staging generation and preserve atomic publication.
pub fn Plan::require_output_free(
  self : Plan,
  available_bytes : Int64,
) -> Unit raise {
  guard available_bytes >= self.minimum_output_free_bytes else {
    fail(
      "native paper checkpoint output filesystem lacks bounded staging headroom",
    )
  }
}

///|
/// Before the streamed motion reader opens files, the retained catalog limits
/// give total control frames <= Int32.max and clips <= 200000. Each clip uses
/// ceil((frames - 1)/50) reset bins. Recompute with the actual bin count after
/// loading; this function neither constructs bins nor reads the motion data.
pub fn unknown_sampler_bins_upper() -> Int32 {
  2147483647 / 50 + 200000
}
