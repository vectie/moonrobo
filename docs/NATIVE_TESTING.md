# Native workspace validation

Run from the MoonRobo root, with the sibling repositories listed in `moon.work`:

```text
moon run scripts/test_native.mbtx /absolute/path/dependencies.json
moon run scripts/test_native.mbtx /absolute/path/dependencies.json src/learning_differential
```

The runner builds and executes the independent ATen oracle, supplies required
model/data/library paths, and runs native MoonBit tests. It neither installs
dependencies nor starts DDS, the E1 SDK or a real-robot controller. Existing
optional device integrations can still print their own explicit skips; this
does not qualify CUDA, Ascend or robot execution.

Example dependency profile (replace every installation path):

```json
{
  "format": "moonrobo.native-test-dependencies.v1",
  "platform": "linux",
  "moonc_version": "v0.10.15+943464bfa",
  "cxx": "/usr/bin/c++",
  "cxx_flags": [],
  "torch_root": "/opt/venv/lib/python3.12/site-packages/torch",
  "mujoco_include": "/opt/venv/lib/python3.12/site-packages/mujoco/include",
  "mujoco_library": "/opt/venv/lib/python3.12/site-packages/mujoco/libmujoco.so.3.15.0",
  "g1_scene": "/data/mujoco_menagerie/unitree_g1/scene_mjx.xml",
  "e1_dataset": "/data/e1-qualified",
  "aligned_data": "/data/g1-aligned-data",
  "blas_library": "/usr/lib/aarch64-linux-gnu/blas/libblas.so.3",
  "build_root": "/work/moonrobo/target/native-tests"
}
```

Use `platform: "macos"` for a `.dylib` build and an explicitly selected LP64
provider such as `/System/Library/Frameworks/Accelerate.framework/Accelerate`.
Compiler flags must match the selected Torch build's C++ ABI. On Linux the
reference `libblas3` package provides unprefixed LP64 CBLAS symbols. NumPy's
prefixed ILP64 OpenBLAS is not interchangeable with that ABI.

The profile pins `moonc -v` as well: this checkout was validated with
`v0.10.15+943464bfa` (12 October 2026). A newer compiler can remove deprecated
syntax accepted by that version. Use an isolated matching toolchain instead of
silently changing the whole workspace's language version during validation.

Required inputs and failure causes resolved in the November 19 sweep:

| Input | Requirement |
| --- | --- |
| MuJoCo | Matching installed headers and library. The runner hashes the selected library and complete header set into its build directory; changing `CPATH` alone can otherwise reuse a headerless native stub. |
| G1 | Actual menagerie `scene_mjx.xml` with its model/mesh dependencies. Supplying only the MuJoCo library caused 18 initialization failures. |
| E1 | Complete qualified dataset including scene, meshes, motion entries, reports, model validation and admission. Metadata-only output archives are insufficient. Use the exact runtime library recorded in admission; do not rewrite its hashes. |
| Motion catalog | Acquired `motion-manifest.json` and all 40 source CSVs. The tests stream real files and verify identities, not a synthetic substitute. |
| ATen oracle | Explicit Torch headers/library and compiler. The runner links a fresh optional oracle on each run. Production does not acquire a new Torch link dependency. |
| BLAS | Explicit `MOONNUM_BLAS_LIBRARY`, supporting LP64 `cblas_dgemm` and `cblas_sgemm`. The native test executes both precisions against portable deterministic products. |

For E1, the preserved qualified dataset used in this task was produced with
Linux AArch64 MuJoCo 3.15.0. Run its qualification tests in that matching
environment. Copying its admission metadata onto a different platform/runtime
does not qualify that runtime. The admission regression checks both the valid
original bundle and rejection of missing evidence, changed reports and changed
motion bytes.

The default native differential profile compares the Float64 scalar learner to
independent Float64 ATen equations, including native corrected rotation/heading
semantics. It also exercises CPU protocol contracts. See the
[precision and provenance contract](../src/learning_differential/README.md).
The strict upstream Float32 verifier retains its exact dtype/weight/moment
checks and executed-upstream provenance requirements. Select that separate
profile by running the differential package directly with an actual
`MOONROBO_SMC_DIFF_FIXTURES` suite; the native runner explicitly selects native
conformance and clears that variable in its child process.

Neither a native conformance pass nor existing optional-device skips establish
paper-level Float32 parity, GPU dynamics, learned-policy quality or real-robot
commissioning. No qualification guard or numeric fixture threshold was weakened
to obtain a green native run.
