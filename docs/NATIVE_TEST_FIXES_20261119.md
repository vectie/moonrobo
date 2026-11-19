# Native test corrections — 19 November 2026

The starting workspace result was 1,887 tests, 1,838 passed and 49 failed.
The [original failure manifest](evidence/workspace-validation-20261119.json)
is retained unchanged. This follow-up distinguishes implementation bugs,
executable conformance tests and missing execution inputs.

The final full native workspace result is **1,890 passed, zero failed**. All 49
prior failures are addressed and three regression tests were added. The 120
existing optional-device skip notices match the baseline exactly, including
their messages; no new skip was introduced. The
[sanitized execution report](evidence/native-tests-fixed-20261119.json) records
the tested source revision, log hash, dependency identities and precision scope.

## Corrections

| Original failures | Resolution |
| --- | --- |
| 28 differential prerequisites | The 27 named methods now execute native conformance, plus the oracle input-clearing regression. The scalar learner is compared with an independent Float64 ATen reference; data and CPU protocol cases execute real production code with explicit expectations. External upstream fixtures remain a separate strict route. |
| 18 G1 physics initialization failures | Supplied the actual menagerie scene and dependencies, matching MuJoCo headers/library and a fresh build. Supplying a library without its required model was insufficient. No substitute simulator was introduced. |
| 2 E1 qualification failures | Used the complete original qualified dataset on Spark, including scene/meshes/motions and evidence, with its recorded Linux AArch64 MuJoCo 3.15.0 library. Local output archives contained only part of that bundle. Admission guards and hashes were preserved. |
| 1 MoonNum BLAS prerequisite | Explicitly selected a real LP64 provider and executed both Float64 and Float32 GEMM comparisons. Accelerate passed locally; the reference Ubuntu `libblas3` provider was supplied for Linux. |

Executing the differential cases exposed a real fixture-decoder bug: the reader
required trailing width 9 and rejected the documented `N×3×3` rotation-matrix
shape. It now accepts both matrix and flattened representations. A regression
checks their equality and rejects malformed trailing axes.

The independent learner reference now has explicitly named `native64` operations.
They use the scalar backend's Double arithmetic and corrected heading/rotation
semantics, while original unprefixed operations retain their upstream semantics.
Tests compare complete outputs, normalizer buffers, raw/applied gradients, Adam
moments and steps, not just losses. Negative cases cover missing/extra keys,
changed moments, shape/dtype mismatches and precision-state isolation after a
failed oracle call. The rotation-fix test compares independently computed
candidate corrections separately from the upstream bug measurements.

The new [native test runner](../scripts/test_native.mbtx) requires an explicit
dependency profile. It pins `moonc` and fingerprints the MuJoCo headers/runtime
into the native build directory. This prevents cached headerless stubs when a
caller changes only `CPATH`. Missing prerequisites still fail; none of these 49
cases was converted into a skip.

The first full Linux run exposed six additional aligned-physics path failures
and one acquired-catalog path failure that the local default paths had masked.
The runner now binds the aligned source G1 scene/motion explicitly, separately
from the menagerie fixture. The catalog regression honors
`MOONROBO_ALIGNED_DATA` while retaining the original default and every SHA,
source-revision and row-count assertion.

Spark's existing compiler was newer than this checkout's compiler and rejected
removed syntax such as `try?`. An isolated `v0.10.15+943464bfa` toolchain, matching
the local compiler, was downloaded from the official distribution. Its AArch64
archive SHA256 matched the published checksum. No system toolchain was replaced
and no unrelated workspace language migration was performed.

## Evidence boundaries

The independent Float64 conformance suite passed all 33 tests locally; the E1
package passed all 25 tests with the qualified dataset/runtime on Spark. Native
API checking completed with zero errors, formatting passed and generated public
interfaces did not change. Existing deprecation and target-declaration warnings
remain.

Strict source-bound upstream Float32 qualification retains exact dtype, weight
and optimizer comparisons and requires actual executed-upstream provenance.
This task did not produce that Python execution evidence. Native conformance
does not qualify bitwise Float32 paper parity, GPU physics or real-robot control.
Existing optional device tests can print explicit skips; those are distinct
from resolving the 49 failures. All remote execution used an isolated software
test workspace, with no DDS, SDK takeover or robot motion.

See [the dependency and precision guide](NATIVE_TESTING.md) to repeat validation.

## Commit sequence

| Commit | Change |
| --- | --- |
| `c0410ce6` | Accept batched rotation matrices and add the decoder regression. |
| `9cec0f5c` | Execute independent Float64 conformance and preserve the strict upstream route. |
| `5df28a36` | Add the explicit dependency/compiler runner and setup guide. |
| `44d851e5` | Bind acquired asset paths and support repeat runs with the same cache. |

The documentation/evidence commit records the final pass without altering
the validated runtime or test code.
