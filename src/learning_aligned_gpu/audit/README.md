# Native checkpoint semantic audit

This CPU-only reader verifies the stored parameters, Adam state and five
normalizers from immutable native checkpoint generation directories. To verify
one saved generation against its recorded held-state digest:

```sh
native-checkpoint-audit \
  --tensor-library /ABSOLUTE/libmoonrobo_learning_tensor.so \
  --generation /ABSOLUTE/generation-N-TIMESTAMP \
  --max-host-mib 8192
```

`--generation` is mutually exclusive with `--left` and `--right`. It uses the
same complete receipt, SHA, sidecar, CPU archive decode and attestation checks
as pair mode. Success emits `moonrobo.native-checkpoint-verification.v1`, with
`verification_passed: true`, `comparison_performed: false` and a single
`generation` result. Its `held_state_attestation_verified` field is true only
when both recorded attestations match the actual decoded learner state; legacy
generations without attestations retain an absent field. A missing attestation
is not evidence of equality with pre-save state. No independent-checkpoint
equality result is emitted.

To compare two generations, use the existing pair mode. It compares canonical
tensor values rather than archive byte hashes, which can differ because
LibTorch stores process-local tensor identifiers:

```sh
native-checkpoint-audit \
  --tensor-library /ABSOLUTE/libmoonrobo_learning_tensor.so \
  --left /ABSOLUTE/RANK0/generation-N-TIMESTAMP \
  --right /ABSOLUTE/RANK1/generation-N-TIMESTAMP \
  --max-host-mib 8192
```

Build the executable from `src/learning_aligned_gpu/audit`. Its Linux memory
admission check applies both the explicit cap and 65% of current available host
memory. Only one generation's model/optimizer state is held at a time. Tensor
digests use bounded host chunks, and no simulator or training loop is started.

The reader accepts v1 and opt-in stream-v2 receipts. It verifies all three model
archives and `state.json` before loading a learner. For v2, typed runtime and
physical metadata enumerate the sidecars; the receipt must contain exactly
those files without duplicate or reserved names. Every sidecar's byte length
and SHA are verified in chunks of at most 64 KiB. Numeric sidecars and catalog
JSON are not decoded by this audit. Its output reports the checkpoint format,
sidecar count and total streamed bytes in addition to shared-state digests.

V2 state metadata is limited to 4 MiB, the catalog to 64 MiB and combined state
plus sidecar payloads to 512 MiB by default. Model archives retain the 512 MiB per-file
limit. The host plan charges for state JSON, model initialization and archive
decoding; streaming payload bytes are not falsely counted as resident arrays.

The only larger profile is an explicit string `"paper-4096"` at
`state.identity.config.capacity_profile`. Missing means `initial`; null,
unknown strings and inferred profiles from large dimensions are rejected.
Paper4096 requires stream-v2 and permits 4096 environments, model batch 2048,
actor batch 4096, replay 1000, each numeric sidecar up to 8 GiB and combined
sidecars plus state up to 10 GiB. Catalog/state/model bounds above remain
unchanged. Both modes check runtime dimensions and typed replay/history/physics
descriptors before model loading. These serialization bounds do not admit a
larger training run or prove that its restoration allocations fit memory.

Successful comparison establishes equality of the audited shared learner state
and the recorded held-state attestation when present. Rank-local replay,
history, sampler and physics values are integrity-checked but not compared or
restored. This does not prove exact APIC resume, physical parity, convergence or
robot readiness. Single-generation verification establishes the recorded
attestation match when present; it does not compare two independent runs.
