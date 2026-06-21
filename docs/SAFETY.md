# Safety Model

Moonrobo must treat physical execution as a privileged side effect.

The safety model is not a later feature. It is part of the first architecture
boundary. A robot can be visible and simulated before the safety gate is
complete, but live control must not bypass it.

## Principles

- Read-only first.
- Simulation before physical execution.
- High-level control before low-level control.
- Receipts for denied attempts as well as successful runs.
- Explicit human approval for risky commands.
- Stale telemetry blocks execution.
- Unknown capability blocks execution.
- Bridge failure blocks execution.
- Silent fallback is forbidden on actuation paths.

## Safety Gate

Every physical command goes through:

```text
CommandIntent
  -> robot profile lookup
  -> capability lookup
  -> bridge health check
  -> telemetry freshness check
  -> mode check
  -> limit check
  -> dry-run / simulation check
  -> approval check
  -> SafetyVerdict
```

The bridge can execute only when the verdict is `allow`.

## Verdicts

Suggested verdicts:

- `allow`
- `deny`
- `approval_required`
- `dry_run_required`
- `stale_telemetry`
- `bridge_unavailable`
- `unsupported_capability`
- `unsafe_mode`
- `limit_violation`
- `developer_gate_required`

Verdicts must include machine-readable reason codes and human-readable detail.

## Command Classes

### Observation

Allowed earliest:

- bridge health
- robot mode
- joint state
- IMU
- joystick
- battery if available
- telemetry recording

Observation should still create receipts when started from a task or standing
goal.

### Simulation

Simulation can accept proposed plans and produce:

- dry-run receipt
- expected motion summary
- model warnings
- missing calibration warnings
- safety precheck result

Simulation does not approve physical execution by itself.

### High Control

High-control commands are named actions exposed by the bridge:

- hold
- stand
- walk
- run
- switch mode
- teach start/save/end/play
- canned action

These may become available after read-only bridge work, but only with approval
and receipts.

### Low Control

Low-control commands include joint position, velocity, torque, stiffness, and
damping. These are blocked by default.

Low control can be introduced only behind:

- developer mode
- local-only bridge access
- explicit RobotBook policy
- reduced test fixture
- hardware-specific limit checks
- emergency stop proof
- human approval

## Emergency Behavior

Moonrobo should define emergency behavior before live control:

- stop or hold command path
- bridge heartbeat loss behavior
- operator disconnect behavior
- stale telemetry behavior
- command timeout behavior
- receipt path for emergency events

The emergency path must be simpler than the normal path.

## Agent Rules

Agents may:

- inspect RobotBooks
- propose command intents
- ask for simulation
- diagnose telemetry and failures
- summarize run evidence
- recommend maintenance
- request operator approval

Agents may not:

- call vendor SDKs directly
- send raw low-level commands
- bypass approval
- convert policy outputs directly into physical execution
- hide bridge errors

## Approval Policy

Approvals should be durable and linked to receipts:

```text
safety/approvals.jsonl
runs/receipts/<receipt-id>.json
```

Approval records should include:

- approver id
- command intent id
- robot id
- safety verdict id
- time window
- constraints
- expiration
- source UI

Approval is not a blanket permission. It applies to a specific intent and
expires.
