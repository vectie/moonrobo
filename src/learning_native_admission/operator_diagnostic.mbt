///|
/// Project a fresh complete paper plan onto the three training phases executed
/// by the independent operator diagnostic. The caller must never checkpoint,
/// restore or resume on this path. Ordinary train/preflight must keep the
/// original plan. Call before with_execution_reserve, add the diagnostic and
/// optimization reserves exactly once, then apply the unchanged assess policy.
/// Every retained component, including allocator caches and full replay, stays
/// unchanged. This is a workload-specific estimate, not a measured memory bound.
pub fn Plan::for_operator_diagnostic(self : Plan) -> Plan raise {
  let expected = [
    "train_collection", "train_world", "train_actor_and_critic", "save_optimizer_archives",
    "save_stream_sidecars_and_publish",
  ]
  guard self.format == "moonrobo.native-paper-phase-memory-plan.v1" &&
    self.capacity_profile == @capacity.Paper4096.name() &&
    self.checkpoint_format == "stream-v2" &&
    !self.restore_phases_included &&
    self.phases.length() == expected.length() &&
    !self.counts.contains("operator_diagnostic_only") else {
    fail(
      "operator diagnostic requires an unprojected fresh complete paper plan",
    )
  }
  for name, _ in self.counts {
    guard !name.has_prefix("execution_") else {
      fail("project operator diagnostic before adding execution reserves")
    }
  }
  let mut source_peak = 0L
  let mut source_peak_phase = ""
  for i, p in self.phases {
    guard p.name == expected[i] && !p.components.is_empty() else {
      fail(
        "operator diagnostic source phases are missing, reordered or duplicated",
      )
    }
    guard p.components.get("distributed_communicator_staging") == Some(0L) else {
      fail("operator diagnostic requires the fresh single-rank plan")
    }
    let mut total = 0L
    for name, value in p.components {
      guard !name.has_prefix("execution_") else {
        fail("project operator diagnostic before adding execution reserves")
      }
      total = add(total, value)
    }
    guard total > 0L && total == p.envelope_bytes else {
      fail("operator diagnostic source component envelope is inconsistent")
    }
    if total > source_peak {
      source_peak = total
      source_peak_phase = p.name
    }
  }
  guard source_peak == self.peak_bytes &&
    source_peak_phase == self.peak_phase &&
    self.required_remaining_bytes == ceil_div(mul(source_peak, 100L), 65L) else {
    fail(
      "operator diagnostic source peak or admission baseline is inconsistent",
    )
  }
  let phases = self.phases[:3].map(p => {
    ..p,
    components: p.components.copy(),
  })
  let mut peak_bytes = 0L
  let mut peak_phase = ""
  for p in phases {
    if p.envelope_bytes > peak_bytes {
      peak_bytes = p.envelope_bytes
      peak_phase = p.name
    }
  }
  let counts = self.counts.copy()
  counts["operator_diagnostic_only"] = 1L
  counts["operator_diagnostic_source_phase_count"] = 5L
  counts["operator_diagnostic_training_phase_count"] = 3L
  let assumptions = self.assumptions.copy()
  assumptions.push(
    "Independent fresh operator diagnostic only: collection/world/actor phases retained exactly; no checkpoint publication, restore or continuation. Ordinary training admission is unchanged.",
  )
  assumptions.push(
    "Add bounded profiler/report storage after this projection. Retained model, optimizer, physics and allocator caches remain live through report/teardown; host/cgroup/CUDA guards must continue through process and trace-export completion.",
  )
  assumptions.push(
    "Checkpoint generation/output and replacement-restore estimates are retained as source-plan provenance only; these operations are not executed or admitted by this diagnostic plan.",
  )
  {
    ..self,
    format: "moonrobo.native-operator-diagnostic-phase-memory-plan.v1",
    accounting_scope: "independent fresh non-resumable operator diagnostic; per-rank combined host/device envelope for unchanged collection/world/actor phases; excludes checkpoint/restore operations which this command must not execute",
    phases,
    peak_bytes,
    peak_phase,
    required_remaining_bytes: ceil_div(mul(peak_bytes, 100L), 65L),
    full_replacement_restore_scope: "not admitted or supported by this diagnostic; retained source-plan estimate only",
    counts,
    device_phase_working_bytes: self.device_phase_working_bytes.copy(),
    assumptions,
  }
}
