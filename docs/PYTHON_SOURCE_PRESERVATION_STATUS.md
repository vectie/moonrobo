# Python source identity verification — 2026-10-24

The cooking/schema/convex/MathDx/device-convergence migration did not edit or delete Python sources. Its parallel edits were limited to new native packages, the MoonBit CLI, metadata tooling and documentation. Current workspace files and the historical inventory are retained as found.

Verification against `PYTHON_MIGRATION_INVENTORY.json` **failed**. An initial passive filesystem/SHA256 snapshot found 126 Python files versus 125 historical rows, with the following three differing identities and one new file. This table records that initial observation, not a continuously current source inventory:

| Path under `providers/motion_learning/aligned/` | Historical SHA256 | Current SHA256 |
| --- | --- | --- |
| `train.py` | `2cba0714d550c237f05c324c37b2f3f43ed09f6ebe57f48aa7cb86da4a4b7906` | `13a5e279304e6820050c801dc335652291a14326981c253d718a0a3bdacb00d7` |
| `learning.py` | `0acd3f8e860e4dea601adbe27363c7c40eaf1427080b872766b13495a919c8ab` | `c0f5e9443b8515edb9b49560a45e40197340bf5a8b0a32842c04347e69c044d4` |
| `networks.py` | `d0e07d29ae8af1d0b6d388475b77efd9e31344d166404231717b2d3a3f0af192` | `59b1694894c64cada571d8f5799f435f2809c8f676905e81bb479ddfb038e251` |
| `distributed.py` | absent | `04584d635da59d400b0e83487f2abec6a6f40ab9e604817a4b25d08dc71b7486` |

The subsequent finalizer checkpoint also reported changed `mdp.py` and `motion.py`, plus new `memory_budget.py` in the same directory. Workspace sources continued changing outside this migration's edit set during verification; attribution to another task has not been established. The latest finalizer's exact changed/added/missing paths are persisted in `MOONBIT_MIGRATION_INVENTORY.json` under `python_original_source_validation.diagnostics`, rather than treating this snapshot as a fresh baseline.

No file was reverted, no baseline was refreshed, and no original-byte archive of the three historical identities in the table was found in `docs/migration-baselines` or `scripts/python_reference`. Historical hashes alone do not establish that the old bytes remain recoverable. Future comparisons must distinguish the historical baseline from current training code.

The inventory verifier now ignores only row ordering, while comparing every top-level field and every full source row; changed, added, missing or duplicate identities still fail. The finalizer continues native metadata recording after a Python identity failure, records `python_original_source_validation.passed=false`, and exits unsuccessfully. It does not silently accept a new baseline. The dependency audit's Python file count explicitly refers to the historical inventory.

The separate 13-file original APIC producer baseline and the pinned upstream source evidence are checked independently. Python identity failure does not establish a failure in those artifacts, nor does their successful verification establish preservation of all Python bytes. No tests, training, simulation or SDK/GPU execution were performed for this report.

The subsequent full cooking/contact/sparse/Newton translation round also edits
no `.py` files. Concurrent workspace Python changes are left intact; neither
the historical inventory nor those sources are rewritten to make verification
pass. New native-source identities and the latest strict verifier diagnostics
are recorded separately by the finalizer.
