# MoonFlow local adapter port

The installed host builds `cmd/moonflow_adapter` as a native executable. It is
the only pack-owned process that translates generic MoonFlow adapter requests
into MoonRobo operations.

```text
capability
declaration
readiness <workspace-root> <robobook-ref>
health <workspace-root> <robobook-ref> <checked-at> <valid-until>
source-bundle <pack.json> <workspace-root> <robobook-ref> <compiled-at> <valid-until>
invoke <workspace-root> <robobook-ref> <moonflow-request.json>
reconcile <workspace-root> <robobook-ref> <moonflow-request.json>
```

`invoke` and `reconcile` emit `moonflow.adapter-result.v1`-compatible JSON.
`source-bundle` emits `moonflow.capability-source-bundle.v1` with the installed
manifest, version-bound adapter declaration and freshly persisted health
evidence. The host verifies the health evidence bytes before compiling the
catalog.

Input artifacts and the RoboBook reference must be relative to the selected
workspace. The adapter rejects traversal and identity conflicts.

The adapter does not expose `physical-effect`. A generic MoonClaw invocation
may integrate a digital model, inspect readiness, or submit a durable command
goal. Physical dispatch remains a later MoonRobo-owned safety, review,
readiness and bridge operation.
