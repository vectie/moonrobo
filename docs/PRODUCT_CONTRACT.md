# MoonRobo product contract

Class: domain product
Maturity: experimental; bounded hardware validation
Last reviewed: 2026-07-30

## Outcome

MoonRobo is the governed boundary between digital plans and robot actions. It
qualifies robot state, applies safety and authority gates, executes through a
device-owned bridge, and records telemetry and proof evidence.

## Users and jobs

- Operators inspect readiness, telemetry, commands, incidents and proof.
- MoonFlow dispatches a typed robot operation after review.
- MoonClaw may reason about a task but cannot call a device directly.
- MoonMoon supplies digital mission/simulation evidence without claiming a
  physical result.

## Ownership

MoonRobo owns robot capability contracts, bridge integration, readiness,
teleoperation constraints, safety interlocks, telemetry evidence, proof
sessions and physical-effect receipts. It does not own the general agent
runtime, orchestration engine, world model or final human authority.

## Capability status

| Capability | Status |
| --- | --- |
| Robot models, readiness and safety policies | available |
| Telemetry, proof-session and cockpit surfaces | available locally |
| Deterministic/digital bridge paths | available |
| Installable pack and MoonFlow adapter v2 | available locally |
| Adapter attempt recovery and reconciliation | available locally |
| SDK E1 bridge | conditional on compatible hardware and operator setup |
| General unattended physical autonomy | excluded |
| Broad hardware fleet support | planned |

## Correct call chain

```text
MoonDesk
→ MoonFlow work/authority state
→ MoonClaw generic agent execution when reasoning is required
→ MoonRobo-owned adapter and safety gate
→ robot bridge
→ telemetry/proof receipt
→ MoonBook accepted outcome and Bookkeeper analysis
```

MoonClaw must not host a built-in robot-routine endpoint. Documentation or tests
that still describe one are legacy and must migrate to the MoonRobo-owned
adapter boundary.

## Physical authority and recovery

Every physical effect requires a separately granted physical authority
envelope, current readiness evidence and an idempotent or explicitly
non-repeatable command identity. Unknown outcomes reconcile against bridge and
telemetry state before retry. Emergency stop and human takeover remain outside
agent discretion.

## Verification

Repository tests prove digital contracts and bounded bridge behavior. A
physical release claim additionally requires named hardware, firmware, safety
configuration, operator, environment, telemetry capture and negative-path
evidence.

## Release gates and next milestones

- Compile the checked-in MoonRobo pack/adapter through the installed MoonFlow
  capability catalog.
- Complete a MoonFlow-dispatched MoonMoon-to-MoonRobo proof loop.
- Validate stop, reconnect, restart, duplicate-command and unknown-outcome
  paths on named hardware.
