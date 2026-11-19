# Learned balance registry export

Parallel native implementation of
`providers/motion_learning/learned_balance_export.py`; the Python source remains.

```text
moon run src/learning_registry/learned/cmd --target native -- --study /path/fit --long /path/long --library /path/libmujoco.dylib --scene /path/scene.xml --output /path/export
```

The driver verifies the long-study→fit-report hash, teacher provider hash,
intervention archive hash and reconstructed `training-sources.json`. It restores
actual logged states and uses the native teacher adapter to regenerate labels,
then rebuilds both h10/full observation features and OLS heads. Every lower/upper
bound, normalization mean/scale and weight must compare exactly against all three
saved heads per window. The six-head gate runs **before** label export or any
success marker; there is no approximate fallback.

After that gate, it writes six gzip training chunks with separate teacher labels,
the representative first dataset, SHA-linked training/export metadata, and the
ten-second/thirty-second h10/full policy and physics reports. Short-study replay
reconstructs actual geometry/contact counts from recorded `next_state` through
MuJoCo forwarding, without stepping or rerunning a policy. Long-study replay is
retained from the original recorded rollout. Existing `.pt` checkpoint bundles and
native `.moon.json` / `.json` bundles are automatically loaded. As in the original
exporter, policy reports reference source checkpoint basenames/digests; this
command does not copy or rewrite checkpoint bytes.

`--teacher-provider-source` overrides `teacher.json.provider_source`, followed by
the charter's `teacher_provider_source`, with the retained
`providers/motion_learning/balance_teacher.py` as the final legacy fallback
(the original scripts imported this provider under the `teacher_feedback` alias).
Its digest must match the teacher report. This is provenance validation, not
Python execution. Native teacher wrapper/kernel hashes are separately recorded;
the imported parameters are evaluated by the native adapter. Native teacher
artifacts name their matching `.mbt` source with `source_language: "moonbit"`;
that actual source digest must match, without substituting an old Python SHA.
`--provider-source` can override the native exporter source path for reports
and must retain its `.mbt` extension. After the strict gate, the exporter saves
that source as `provider-sources/learned_balance_export.mbt` and records
`provider_source`, `provider_snapshot`, `provider_sha256`, and `source_language`.
When multiple `.pt`/`.moon.json`/`.json` heads share a basename the exporter
rejects ambiguous selection rather than silently preferring one serialization.

`scripts/export_g1_learned_balance.mbtx REPO FIT LONG OUTPUT` is now a native
launcher through `scripts/run_native_learning.mbtx`. Set
`MOONROBO_MUJOCO_LIBRARY` or pass `--library`, with optional `--scene`. The original
launcher is retained byte-for-byte under `scripts/python_reference`. The new
launcher preserves incoming comparison sources separately, archives native
source bytes (including shared numeric/physics modules) and hashes, and checks
those source hashes again after export. Build manifests use a `.source` snapshot
suffix so an exported archive does not accidentally become buildable packages
inside the main workspace. Model links use the exact checkpoint basenames and
digests emitted by the exporter: native JSON is never renamed to `.pt`.

Native reconstruction/QR OLS uses f64; original Torch feature buffers/inference
were f32 and the original fit used LAPACK `gelsd`. Such differences can make an
old `.pt` head fail exact reproduction. That failure is intentional: the exporter
does not round coefficients, widen tolerances or assert original parity. Emitted
native training labels declare f64 rather than falsely retaining the original
`float32` label claim. Exact equality alone enables
`exact_refit_matches_all_six_heads: true`.

Validation: native `moon check` on driver/CLI and authored strict-gate tests only.
No refit/export/audit/test or simulator execution was performed during migration.
