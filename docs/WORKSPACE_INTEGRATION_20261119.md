# Complete workspace integration — 19 November 2026

This integration includes all outstanding MoonRobo source, documentation,
automation, examples, retained reference implementations and intentionally
published UI assets present at the start of the review. It extends the earlier
four E1-only commits rather than replacing or reverting them. LunaFlux,
LunaKine, MoonNum and Moonphys remain separate repositories; their source is
not silently copied into MoonRobo.

Native-test follow-up: the subsequent correction pass reports **1,890 passed,
zero failed**, addressing all 49 failures below and adding three regressions.
The 120 existing optional-device skip notices are unchanged. See
[the corrections and precision boundaries](NATIVE_TEST_FIXES_20261119.md) and
[execution evidence](evidence/native-tests-fixed-20261119.json). The integration
baseline below is preserved as the historical result, including its failures.

## Commit sequence

| Commit | Scope |
| --- | --- |
| `81ecdc72` | Core integer/API compatibility, shared MoonNum facade/geometry, workspace module dependencies and original numerical-source baseline. |
| `db4596eb` | Optional LibTorch/CUDA backend, checkpoint streaming, admission/memory contracts, profiling and NCCL diagnostics; Spark build containers. |
| `1489efed` | Native APIC model/cooking/contacts/solver/compiler packages and retained mjlab provider. |
| `64f77db7` | Motion datasets, reference registry, model/actor/critic learning, aligned/GPU learner, replay registration, evaluation and training CLIs. |
| `831a4cfb` | LunaKine actor adapters, local policy/task supervision, E1 observations/mapping, native SDK sidecars, host integration and SDK ABI fixtures. |
| `75fc6314` | Learning cockpit, G1/E1 showcases, held-out comparisons, replay/orientation/arm tools, model/motion assets and trained-actor downloads. |
| `744c14a8` | Authored job/analysis automation, retained Python reference/oracle code, runnable examples, comparison deployment and the requested comparison workbook. |
| Final documentation commit | Existing research/engineering findings, source-evidence manifests, APIC migration baseline, navigation and this validation record. |

The native APIC and training implementations contain substantial source and
fixtures. Their presence is not an assertion that every CUDA kernel, native
producer route or learned controller is qualified. The retained Python sources
remain distinct from the native migration and its historical source-identity
findings. No existing failing preservation baseline was silently updated to
claim equivalence.

One-off authoring and migration scripts are retained as source history. They
can require the original benchmark archives, SDKs, compiler revisions or host
paths; they were not all executed during this integration.

## Validation and corrections

The full native type check completed with zero errors. `moon info` and
`moon fmt` were run across the workspace, and generated interfaces were
reviewed alongside their source. Existing compiler/dependency deprecation,
target-declaration and implicit-method warnings remain; this is not a
warnings-free result. Python reference/provider files pass syntax compilation,
which does not execute or qualify their numerical behavior.

The frontend suite reports **169 tests: 163 passed, zero failed, six skipped**.
The skipped tests require a separately running native HTTP/registry integration.
The full cockpit production build passes, including E1/G1, comparison, workflow,
orientation and arm pages. Vite still reports large bundle warnings. The
standalone E1 live-view scripts from the earlier series remain available.

The initial full native sweep exposed local issues that were corrected:

- Replay root-body decoding now accepts explicit JSON `null` as well as an
  omitted parent. Non-string parent values still fail; a regression covers
  these cases. Replay registration now retains the existing root representation.
- Late-window comparison MSE is serialized as a scalar or JSON `null`, rather
  than the language's optional-value array encoding. Existing independent
  expected-value tests cover the populated scalar case.
- Temporal checkpoint tests and checkpoint-copy tests use atomic unique
  temporary directories, avoiding existing-directory failures and races.
- The Newton pipeline fixture supplies a valid nonzero mass-storage count
  before exercising its intended rejection of a convergence-only loop.
- Browser benchmark tests use retained small fixtures in `testdata/`, rather
  than requiring an ignored local `output/` directory. The live asset test also
  accepts the now-restored motion library and retains mesh/hash checks.

The replay/registration subset passes 19 tests. The corrected comparison,
temporal, checkpoint-copy and pipeline subset passes 32 tests. Three genuine
local physics contracts also pass with matching MuJoCo 3.3.7 headers/library.
No simulator fallback was substituted for unavailable native physics.

The final full native **workspace** sweep reports **1,887 tests: 1,838 passed,
49 failed**. This includes sibling-module tests and explicit optional-device
skips printed inside some tests. The full suite is **not green**:

| Observed category | Failures | Meaning |
| --- | ---: | --- |
| Upstream differential fixtures/adapter | 28 | Tests explicitly require real source-bound SMC fixtures or the native oracle adapter; fabricated data and automatic skips were not introduced. |
| Native physics initialization/fixture | 18 | Tests report `PhysicsError.Invalid`. Matching headers/library alone did not qualify their required model/fixture paths; these remain unresolved failures. |
| E1 qualification inputs | 2 | Tests require the actual E1 model and a qualified dataset. Existing simulated or browser artifacts were not promoted into qualification evidence. |
| Shared MoonNum BLAS | 1 | A sibling-module differential test requires an explicit native BLAS library. |

The [sanitized validation report](evidence/workspace-validation-20261119.json)
lists all 49 failing test names, categories and original log hashes. It avoids
publishing machine-specific raw logs. These categories describe observed
diagnostics, not a blanket claim that all remaining failures are environmental.
Hardware-specific LibTorch/CUDA/NCCL/Ascend integrations that print SKIP are
not counted as newly validated device execution. The earlier
[E1 commissioning findings](E1_COMMISSIONING_FINDINGS.md) retain their own
separate hardware evidence and handback limitations.

## Artifacts and reproducibility

The 7.8 GB `output/` scratch/capture tree is retained locally and explicitly
ignored. Existing `target/`, `_build/`, dependency trees, `.env.local`, extracted
CAD packs, compiled test outputs and robot capture files are not published as
source. The small public UI result/motion assets and trained actor ZIPs are
included intentionally because the committed website uses them. Individual
files are below GitHub's 100 MB file limit. Supplied Noetix, Unitree and font
notices are retained, as are hashes for browser model/motion files.

The original checkout was left unchanged during integration, audited for source
edits after the snapshot, and backed up before synchronizing its `main` branch.
The commit series was assembled in a separate worktree so the existing E1
fixes and the wider source changes could be combined without discarding either.
Credentials and raw powered-robot captures were not staged. This task performed
software builds/tests and source publication, not another real-robot motion.

Useful entry points:

- [Documentation map](README.md) and [engineering proposal](engineering/README.md).
- [Selected LunaKine architecture](LUNAKINE_DEPLOYMENT_PLAN.md) and
  [implementation history](LUNAKINE_IMPLEMENTATION_PLAN.md).
- [Native APIC translation](APIC_FULL_NATIVE_TRANSLATION.md) and
  [Python dependency boundaries](PYTHON_DEPENDENCIES.md).
- [Tensor backend](../src/learning_tensor/README.md),
  [aligned learner](../src/learning_aligned_gpu/README.md),
  [E1 runner](../src/e1_actor_control/README.mbt.md) and
  [cockpit](../ui/rabbita-cockpit/README.md).

`scripts/archive_workspace_validation.mbtx NATIVE_LOG UI_LOG NEW_REPORT`
regenerates the sanitized test manifest from completed logs. This utility only
reads files and hashes; it does not start a runtime, simulator or DDS session.
