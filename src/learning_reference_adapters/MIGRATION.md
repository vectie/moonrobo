# Native reference and aligned entrypoints

The default entrypoints in the table below run MoonBit implementations. The
29 original scripts are preserved byte for byte in
[`scripts/python_reference`](../../../scripts/python_reference), with their
SHA-256 identities in `reference-aligned-sources.json`. Original Python source
files are unchanged. Calling an archived script is an explicit historical
workflow; no default entry chooses Python or falls back to it.

`cmd/reference_scripts` parses the original worker flags, rejects unsupported
options and calls the real migrated algorithms. Its `.py` entry tokens select
documented historical contracts; they are neither read as code nor executed.
The outer `.mbtx` scripts still prepare charters, preserve source artifacts,
validate records and generate registry evidence. This is more than changing an
executable name: native feedback/model imports, complete study drivers, RNG
callbacks, checkpoint paths, source hashes and output streams are adapted.

| Original/default script | Default implementation |
| --- | --- |
| `collect_g1_full_body_reference.mbtx` | `learning_balance/reference_study.run`, including teacher-source binding, collection, replay and complete report |
| `fit_g1_reference_initialization.mbtx` | `reference.run_initialization_study`, native feedback import, all configured fits and physical coverage |
| `fit_g1_reference_learning.mbtx` | `reference.run_learning_study`, matched methods and optional reused study |
| `fit_g1_reference_final_route.mbtx` | `routes.run_final_route`, exact reconstruction and matched fork protocol |
| `probe_g1_reference_last_cycle.mbtx` | `reference.run_last_cycle`, optional actual ATen CPU random-index callbacks |
| `probe_g1_reference_action_response.mbtx` | `directions.run_action_response` |
| `probe_g1_reference_feedback_response.mbtx` | `directions.run_feedback_response` |
| `probe_g1_reference_gradient_route.mbtx` | `routes.run_gradient_route` |
| `probe_g1_reference_root.mbtx` | `roots.run_integration` |
| `probe_g1_reference_tail.mbtx` | `routes.run_tail_directions` |
| `report_g1_reference_initialization.mbtx` | Native initialization export stream and existing independent dataset/metric checks |
| `report_g1_reference_learning.mbtx` | Native imagination probe and learning export stream, including original methods/offsets and all verification gates |
| `report_g1_reference_last_cycle.mbtx` | Native learning export stream and existing last-cycle accounting checks |
| `report_g1_reference_action_response.mbtx` | Native action-response export stream |
| `report_g1_reference_feedback_response.mbtx` | Native feedback-response export stream |
| `report_g1_reference_gradient_route.mbtx` | Native learning export stream and unchanged directional verification gates |
| `report_g1_reference_final_route.mbtx` | Native independent actor-update-state reload gate plus complete export stream |
| `report_g1_reference_root.mbtx` | Native root export stream and decomposition/accounting checks |
| `export_g1_reference_registry.mbtx` | Existing complete artifact packaging plus `reference.export_initialization_registry`; baseline checkpoint is the actual native `.json` |
| `export_g1_reference_learning_registry.mbtx` | Existing complete inherited-artifact packaging plus `reference.export_learning_registry` |
| `run_g1_aligned.mbtx` | Native aligned training CLI, directory → `checkpoint.json`, `report.json`, `evaluation.json`; effective configuration records explicit backend/device overrides |
| `register_g1_aligned.mbtx` | Native JSON replay export, or strict passive original Torch replay import; native dataset validation and registry commands |
| `export_g1_aligned_apic.mbtx` | Existing native APIC exporter, unchanged |
| `prepare_g1_aligned_data.mbtx` | Existing MoonBit download/identity preparation, unchanged |
| `register_g1_reference_registry.mbtx` | Existing MoonBit registry commands, unchanged |
| `report_g1_full_body_reference.mbtx` | Existing MoonBit archived-physics/metric verification; native source bindings |
| `prepare_g1_reference_replay.mbtx` | Existing MoonBit replay preparation, unchanged |
| `prepare_g1_reference_extension.mbtx` | Existing MoonBit charter preparation, unchanged |
| `summarize_g1_reference_extension.mbtx` | Existing MoonBit report summarization, unchanged |

Reference native processes require an explicit `--library` or
`MOONROBO_MUJOCO_LIBRARY`. They never launch Python to discover a wheel/library.
`MOONROBO_TORCH_RNG_ADAPTER` enables the existing optional C++ ATen CPU RNG
adapter for legacy reconstruction. Native algorithm arithmetic remains
Float64, so matching an old random stream does not establish Float32 parity.
Original source hashes, numerical gates, budget and record counts are retained.
The seven source-bound probe/final-route scripts accept an additional optional
`CONFIG_JSON`; frozen original example hashes are not silently refreshed for a
new native experiment. Input paths are interpreted relative to the repository
working directory used by the native process.

Native training reports identify the real `.mbt` provider files, a hash of
`native-sources.json`, and an archived implementation tree under
`native-provider-sources`. Canonical numeric/physics workspace dependency source
trees are included. Historical Python copies are explicitly not the executed
provider. Report scripts hash the archived native files. Native collection
storage remains Float64; old numeric archives remain Float32. Verification
checks the declared record dtype and keeps the original error thresholds.

The passive Torch importer follows `aligned/buffer.py::state_dict`: occupied
rows are already chronological, with `[size,num_envs,...]` dimensions. It requires
all eleven tensors, the original floating/integer/boolean dtypes, finite values,
integral nonnegative frame/step indices, legal occupancy and
`done == terminated | truncated`. The checkpoint SHA, report identity/config,
compiled scene SHA and complete motion inventory hashes are checked. It uses
the actual production `aligned.decode_replay`, real compiled MuJoCo addresses,
world-to-body angular velocity conversion, observation reconstruction and
preview goals. It does not infer absent replay or resume learner/optimizer/RNG/
physical state. Unknown pickle globals/opcodes or unsupported schema fail
explicitly in the data-only reader; no pickle code is executed.

For native Isaac replay export, registration additionally accepts the original
`PHYSICS_LIBRARY PHYSICS_ARTIFACT` paths, preserving checkpoint identity checks.
Old Torch replay export is passive and does not require launching a GPU solver.
Native numerical training requires CPU Float64 and no AMP; unsupported CUDA
learner/device and raw Python USD options fail explicitly instead of being
ignored. Native APIC artifact production has its separate unchanged entrypoint.

Validation in this change is source-only. The new adapter package and CLI
passed native type checking, including three authored importer tests; tests
were not executed. The initial launcher batch encountered filesystem exhaustion;
the final shared-target entrypoint checks and source identities are recorded in
`docs/MOONBIT_MIGRATION_INVENTORY.json`.
No actual checkpoint was decoded, dataset exported, RNG sampled, SDK launched,
training or simulation run. Float32 numerical agreement and complete run-output
parity remain unverified; no test or physical-quality pass is claimed.
