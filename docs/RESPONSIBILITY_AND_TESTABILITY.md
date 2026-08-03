# MoonRobo responsibility and testability

MoonRobo owns the governed boundary from reviewed digital intent to a
device-owned bridge. The ordinary cockpit path is evidence → evaluation →
dry-run → named approval → explicit execution.

## Responsibility boundary

| Concern | Owner | MoonRobo seam |
| --- | --- | --- |
| Agent reasoning and workflow scheduling | MoonClaw / MoonFlow | Accepts bounded typed operations; creates no second runtime. |
| World and mission simulation | MoonMoon | Consumes digital evidence without treating it as readiness. |
| Robot model and spatial input | MoonRobo / MoonMold | MoonRobo validates product-owned model inputs before use. |
| Safety, readiness, bridge and telemetry | MoonRobo | Owns evaluation, dry-run, approval binding, effect and receipt. |
| Human authority and emergency takeover | Operator / host | Never delegated to an agent. |

`ui/rabbita-cockpit/main/operator_flow.mbt` is a presentation component over
the existing safety messages; it does not bypass backend policy. Editing a
command clears its prior dry-run receipt and approval in the UI model so stale
authority is never presented as reusable.

## Test seams

- Domain packages test readiness, bridge idempotency, reconciliation,
  telemetry and recovery independently of the cockpit.
- `ui/rabbita-cockpit/main/view_wbtest.mbt` asserts the five-stage operator
  path, visible denial and evidence invalidation after edits.
- `docs/qualification/UI_TO_UI_USE_CASES.md` owns rendered digital and named
  hardware qualification records.

Untracked observation and telemetry captures are operator-owned evidence and
must not be deleted or rewritten by source refactors.
