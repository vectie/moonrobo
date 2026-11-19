# Bounded execution-profile probe

This native executable does not compile the repository test suite. It tests the
optional profiler against an explicitly selected tensor plugin, with fixed
Float32 `[2, 3]` forward/backward arithmetic and no training or RNG.

```sh
moon build --target native --release src/learning_tensor/profile_probe
```

Run the resulting executable with `/absolute/plugin.so cpu` or
`/absolute/plugin.so cuda`. CUDA mode requires an actual device 0, memory
telemetry support and at least 1 GiB free CUDA memory. Use the enclosing process
memory limits and timeout; this small probe does not establish training capacity.

The probe compares profiled and unprofiled outputs and gradients exactly, checks
the analytic values, records nested scopes, cancels an intentional failing scope,
verifies subsequent arithmetic, and checks the six-span cap. At most twelve CUDA
events are recorded. One snapshot is queried without waiting; CUDA mode then
uses **one explicit memory-telemetry synchronization boundary** and requires all
five non-cancelled intervals to be complete. The report does not require the
first snapshot to contain pending intervals, because this tiny workload may
already have completed. CPU mode must not fabricate CUDA durations.

Success emits `moonrobo.execution-profile-probe.v1` JSON containing both raw
profile snapshots, completion counts, memory telemetry and parity flags. Missing
NVTX support is reported by the profiler rather than treated as successful NVTX
validation. Failure emits a failed report and exits nonzero. This is a functional
probe, not a timing benchmark or proof of full training equivalence.
