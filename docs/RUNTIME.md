# Moonrobo Runtime Slice

This slice turns the planning documents into a native MoonBit runtime path that
Rabbita and Lepus can build on.

## Current Runtime Boundary

The current runtime is intentionally small:

- load a RobotBook from disk
- decode `robot.json` into the MoonBit `RobotProfile` contract
- inspect required RobotBook paths
- produce deterministic mock telemetry
- pass a command intent through the safety pipeline

It does not start hardware sidecars or issue motion commands yet. The purpose is
to establish the file, contract, validation, and pipeline shape that the
operator interface can trust.

## Native CLI

The native CLI is the first stable integration seam:

```text
moon run cmd/main --target native -- inspect [robotbook-root]
moon run cmd/main --target native -- mock [robotbook-root]
moon run cmd/main --target native -- plan-walk [robotbook-root]
```

Default root:

```text
examples/noetix-e1
```

Command meanings:

- `inspect`: load and validate the RobotBook, then summarize identity,
  readiness, joints, capabilities, missing files, and validation issues.
- `mock`: load the RobotBook and emit one deterministic telemetry summary from
  the mock bridge.
- `plan-walk`: create a high-level walk intent and evaluate it through the
  safety pipeline. It should currently stop at dry-run collection.

## Rabbita/Lepus Path

The Rabbita cockpit should call into the same runtime contracts instead of
recreating robot parsing or safety checks in UI code.

Near-term screens should map directly to the CLI path:

- RobotBook picker and readiness summary from `inspect`
- mock bridge health and telemetry from `mock`
- proposed-command review from `plan-walk`

The Lepus desktop shell should package the native runtime and supervise later
sidecars. Scoped filesystem access belongs in Lepus; robot contract logic stays
in MoonBit packages.

## Reference Direction

The sibling robot-canvas work and local SDK remain references for model loading,
file access, hardware configuration, and bridge behavior. Moonrobo should reuse
that learning while keeping its own product boundary: physical-world agent
operation with RobotBooks, safety gates, receipts, and Moontown-visible robot
residents.

## Next Runtime Steps

1. Replace the mock bridge with a read-only sidecar bridge that reports SDK
   health and telemetry.
2. Add a bridge JSON request/response parser under MoonBit tests.
3. Persist mock run receipts into the RobotBook receipt directory.
4. Expose the runtime through a Rabbita read-only cockpit.
5. Package the same flow in a Lepus desktop prototype.
