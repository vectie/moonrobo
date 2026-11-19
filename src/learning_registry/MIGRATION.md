# sustained_balance_export.py

`sustained_export.mbt` ports the original archive-to-registry pipeline: require the 15-checkpoint train-only reproduction proof; verify all three source physics log hashes; materialize the representative gzip dataset; reconstruct MuJoCo geometry/contact traces from recorded states without policy inference or simulation stepping; group exactly nine canonical teacher/candidate trials; compare original selected summaries; hash selected checkpoint files; emit per-seed physics JSON, policy report and export manifest with original registry contracts.

The exporter accepts original report/archive/checkpoint filenames. It hashes checkpoint files without interpreting their serialization. `--library` is an extra native requirement compared with Python's imported MuJoCo module. Run from repository root so the default provider source path resolves:

```console
moon run src/learning_registry/cli -- sustained STUDY MUJOCO_LIBRARY SCENE OUTPUT
```

No export, simulation, policy inference or tests were run. Native type checking is the current validation. New gzip/JSON encoding produces its own stored-byte hash and is not expected to reproduce Python's compressed bytes. Data/trial/qualification semantics remain subject to the later differential check.

This package does not implement the preceding sustained training/architecture-selection study or prove that an external verification report is truthful. It applies the original exporter's mandatory proof/hash gates. The generic physics reconstruction helper is also reusable by other registry exporters.

`scripts/export_g1_sustained_balance.mbtx REPO STUDY OUTPUT` now calls this native
CLI through `scripts/run_native_learning.mbtx`. A MuJoCo library must be supplied
with `--library` or `MOONROBO_MUJOCO_LIBRARY`; optional `--scene` and
`--study-report` retain the original default model/report paths while allowing
explicit relocation. There is no interpreter-based discovery or fallback. The
original launcher remains under `scripts/python_reference` for future comparison.

The exporter records its actual MoonBit `provider_source`, digest,
`provider_snapshot: "provider-sources/sustained_balance_export.mbt"`, and
`source_language: "moonbit"`. The launcher keeps original reference source
bytes separately from native source snapshots and links checkpoint files using
the report's real basename and matching SHA, preserving `.pt` and `.moon.json`
serialization identities. Native source manifests include the shared MoonBit
numeric/physics modules; build manifests are copied with a `.source` suffix to
prevent the archive becoming additional workspace packages. No export launcher,
refit, simulation, SDK or test was executed during this wiring change.
