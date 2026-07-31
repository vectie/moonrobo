# MoonRobo pack adapter

MoonRobo 0.2.0 is an installable domain pack and a product-owned
`moonflow.adapter.v2` implementation. It does not add robot policy or hardware
code to MoonFlow or MoonClaw.

## Executable operations

| Tool ID | Canonical operation | Authority | Input → output | Effect ceiling |
| --- | --- | --- | --- | --- |
| `robot.integrate-digital-model` | `moonrobo/robot.integrate-digital-model@0.2.0` | `WorkspaceMutation` | `moonsuite.robot-design.v1` → `moonrobo.digital-model-integration-receipt.v1` | digital artifact |
| `robot.readiness.inspect` | `moonrobo/robot.readiness.inspect@0.2.0` | `Observe` | `moonrobo.robobook-ref.v1` → `moonrobo.readiness-observation.v1` | observation |
| `robot.command.submit-governed` | `moonrobo/robot.command.submit-governed@0.2.0` | `WorkspaceMutation` | `moonrobo.robot-command-goal.v1` → `moonrobo.governed-command-submission.v1` | durable task ingress |

No operation exposes `physical-effect`. `robot.command.submit-governed` records
an agent-authored goal through MoonRobo’s gateway/task ledger and stops at the
next product-owned gate.

## Capability truth

The source of truth is split deliberately:

- [`pack.json`](../pack.json) owns schemas and tool IDs.
- [`moonrobo-local-v1.declaration.json`](../adapters/moonrobo-local-v1.declaration.json)
  binds the installed pack version to `moonflow.adapter.v2`.
- A runtime `moonflow.adapter-health.v1` attestation covers only operations
  whose current adapter/RoboBook readiness probe passed.

The host can generate a complete MoonFlow source bundle:

```sh
moon run cmd/moonflow_adapter -- source-bundle \
  pack.json \
  /path/to/workspace \
  books/<book-id> \
  2026-07-31T00:00:00Z \
  2026-08-01T00:00:00Z
```

MoonFlow compiles the resulting operation identities before importing a graph.
An invented or unversioned canvas verb is not executable.

## Invocation and evidence

`invoke` accepts MoonFlow’s generic adapter request plus a host-selected
workspace and RoboBook reference. Every attempt persists:

```text
.moonsuite/products/moonrobo/adapter-attempts/<attempt-id>/
  request.json
  attempt.json
  operation-receipt.json
  adapter-result.json
  reconciliation.json
```

Exact repeated requests return the first terminal result. A started attempt
without a terminal result cannot execute again.

## Unknown outcomes

`reconcile` checks evidence in this order:

1. terminal adapter result;
2. immutable operation receipt;
3. matching digital-design build/validation evidence;
4. matching gateway-command evidence;
5. partial-effect evidence.

It returns `recovered-succeeded`, `recovered-failed`, `not-applied`, or
`unknown`. Only `not-applied` permits MoonFlow to create a retry attempt.
Partial or conflicting artifacts remain blocked for human investigation.

## Physical continuation

After governed command ingress, MoonRobo still requires its normal task
evaluation, dry-run, approval, runtime validation, exact robot/bridge identity,
bridge dispatch, telemetry and feedback binding. Emergency stop and operator
takeover are never delegated to a generic agent.
