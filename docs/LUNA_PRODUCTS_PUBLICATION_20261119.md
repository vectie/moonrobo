# Luna product repository publication — 19 November 2026

All nine GitHub `main` branches were verified against their local heads after
the pending work was committed in separate coherent steps. The final audit
found clean working trees in all nine repositories. The
[machine-readable ledger](evidence/luna-products-publication-20261119.json)
contains full commit identities, repository URLs and recent commit sequences.

| Repository | Published main | Validation in this pass |
| --- | --- | --- |
| LunaNexa | `07d29c1` | Native warning-denied check; 70 documentation/site tests passed, one existing browser skip; 13 video transport tests passed |
| LunaChip | `22eb47e` | 1,421 warning-denied native tests passed; subsequent mapping-preparer compilation reached its expected no-argument usage guard |
| LunaFlux | `d3a7d626` | 5,544 Linux native tests passed, ten explicit optional asset skips; three local callback regressions passed |
| LunaKine | `d8f39a4` | Six native tests, three real C ABI test-double checks and six ASan checks passed; optional real-device fixtures remain separate |
| LunaFlex | `881ee3c` | 819 native tests passed after updating removed integer parser calls and compiler spellings |
| LunaRein | `6bb2ebe` | 99 native tests and architecture boundary checks passed |
| MoonNum | `9a4d50c` | 25 native tests passed with explicit LP64 Accelerate BLAS |
| Moonphys | `be25aa3` | 127 workspace tests passed, including the 25 MoonNum dependency tests |
| MoonLib | `f9cad48` | Already clean and up to date; no empty commit was created |

These counts are separate, potentially overlapping software scopes. Optional
asset/device notices do not qualify physical GPU/NPU/FPGA execution or model
quality. LunaFlux's warning-denied native check still reports compiler migration
diagnostics; LunaRein's warning-denied check also remains open. Their ordinary
native test passes are recorded separately, without disabling warning flags.
LunaFlex retains compiler deprecation warnings as documented in its publication.

The macOS LunaFlux run initially failed two large checkpoint fixture writes
because the local disk was full. The complete run was repeated on Linux with
enough storage. A callback-retirement test race found there was repaired by
waiting for service readiness before asserting the same exact retirement
count. The final full Linux run passed. Fixtures, assertions and sizes were not
reduced.

Additional LunaChip edits arrived during publication. They were reviewed and
published separately: the 120/300/200 MHz board measurement records, source
clock handling in bank-map preparation, and the latest routed mapping status.
Three small measurement reports were retained byte for byte with SHA256
inventory under LunaChip's `docs/evidence/`. Their physical claims belong to
that recorded FPGA work; this publication pass did not rerun hardware.

Ordinary pushes were used throughout. LunaChip's oversized historical object
was outside `main`; the main-only audit found no blobs over 100 MiB, so its
history was pushed unchanged. Original refs and a verified local Git bundle
remain available. No force push or historical archive rewrite was performed.
Ignored weights, deployment captures, generated caches and raw output trees
remain local. Unique numerical evidence and sealed archives were preserved.

MoonRobo's own commits separately implement and document the
[executed-upstream Float32 result](UPSTREAM_FLOAT32_QUALIFICATION_20261119.md):
54 original Python methods, two strict native world/actor cases with 327
zero-difference outputs, 319 bit-identical non-metric Float32 payloads, and the
final 1,891-test native workspace pass.
