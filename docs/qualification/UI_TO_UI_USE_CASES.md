# MoonRobo UI-to-UI qualification

Last reviewed: 2026-07-31
Surface: Rabbita cockpit
Product class: governed robot readiness, command intake, and evidence

## Safety truth

This qualification intentionally runs without a qualified physical SDK
runtime. A useful pass is therefore:

- the cockpit loads one RoboBook and its digital twin;
- non-physical bootstrap and evidence inspection work;
- readiness identifies exact physical blockers;
- command-like requests go through MoonClaw-owned reasoning and MoonRobo-owned
  authority checks;
- no physical command is executed while runtime validation is blocked.

The browser is never a raw hardware bridge.

## Prerequisites and launch

```sh
cd /Users/kq/Workspace/moonrobo
npm --prefix ui/rabbita-cockpit run build
moon run cmd/main --target native -- serve \
  examples/noetix-e1 \
  ui/rabbita-cockpit/dist \
  127.0.0.1 \
  5290 \
  127.0.0.1 \
  5391
```

Open:

```text
http://127.0.0.1:5290/
```

Health and evidence routes used by the UI:

```text
http://127.0.0.1:5290/__moonrobo_health
http://127.0.0.1:5290/api/cockpit/snapshot
http://127.0.0.1:5290/api/moonrobo/readiness
http://127.0.0.1:5290/api/moonrobo/gateway-status
```

## R1 — positive digital readiness loop

1. Open the cockpit and verify the robot/model viewport renders.
2. Locate **Platform Readiness**.
3. Inspect pass/fail counts, selected robot, runtime, evidence root, current
   report, live readiness, loop proof, and remediation actions.
4. Click **Bootstrap Platform**.
5. Expect only safe readiness work:
   - tool registry initialization;
   - MoonBook memory/task-message evidence;
   - refreshed readiness report.
6. Verify `physical_execution_allowed` remains false while the SDK/bridge
   contract, active supervisor, telemetry, and repeated validation are absent.
7. In **Ask Robo**, enter:

   ```text
   Inspect the selected robot and report the next safe readiness step.
   ```

8. Click **Ask Robo**.
9. Expect a persisted task-message/conversation entry and a handoff toward the
   next safe route. If the external MoonClaw gateway is unavailable, expect an
   explicit blocked/degraded result while the user message remains durable.
10. Click **Refresh Ledger** and verify the same message is restored.
11. Click **Prove Loop**. Expect a proof artifact that names the first missing
    gate rather than claiming physical completion.

## R2 — governed command denial

1. In **Ask Robo**, enter:

   ```text
   Walk forward 0.5 metres now.
   ```

2. Click **Run Loop**.
3. Verify command-like intent is classified for review and routed to
   MoonClaw/MoonRobo’s gateway boundary.
4. With no qualified runtime, expect denial at live readiness/runtime
   validation. There must be no executed receipt.
5. Click **Prove Runtime**. Expect evidence of the absent/incomplete supervisor,
   bridge contract, telemetry identity, or validation session.
6. Do not use **Start Runtime** unless the selected real SDK, bridge endpoint,
   emergency stop, and operator authorization have been qualified.

Passing evidence for this case includes:

- a blocked command or review handoff;
- `physical_execution_allowed: false`;
- the failing readiness check and exact next safe route;
- no `Executed` physical command receipt.

## R3 — recovery

1. Complete R1 through bootstrap, a task message, and loop proof.
2. Record the visible report ID, message count, and latest evidence paths.
3. Restart only the desktop host with the same RoboBook root.
4. Reload the cockpit.
5. Verify task messages, MoonBook memory, readiness evidence, and proof history
   return from durable records.
6. Click **Refresh Ledger** and **Prove Loop** once.
7. Confirm restart did not mark missing physical feedback as verified and did
   not replay a command.

## Physical-runtime acceptance, when hardware is intentionally in scope

This is a separate qualification and must not be inferred from R1–R3. Before a
command can be accepted, require:

1. active supervised collector, writer, and bridge;
2. healthy live telemetry for the selected robot/bridge identity;
3. matching bridge authority contract with `ExecuteIntent` and
   `EmergencyStop`;
4. repeated runtime-validation session;
5. named command review and bounded command;
6. command receipt;
7. post-dispatch telemetry feedback with matching identity and timestamp;
8. human-verifiable emergency stop.

## MoonMold ingestion truth

`src/spatial_import` validates a portable engineering envelope and correctly
rejects stale parent geometry, lossy transforms, invalid digests, wrong
consumers, or elevated claim ceilings. The published cockpit currently has no
route or form for that portable envelope. Contract-level ingestion is
testable; MoonMold-to-MoonRobo UI-to-UI ingestion is not yet implemented.

The current MoonMold operator output also is not a rename-compatible input. It
lacks the composite manifest/transform structure, exact editable-parent and
engineering-child bindings, spatial conventions, consumer policy, authority
reference, assumptions, and unresolved-gap fields required here. The repair
belongs in a versioned MoonMold portable exporter or shared pack contract, not
in an ad hoc cockpit mapper.

## Qualification record

- Source/build validation: passed (`moon check --warn-list +73`, all 3
  `src/spatial_import` tests, Rabbita production build, and `moon info`;
  existing warnings only)
- Cockpit build and host: passed at `/`
- Safe bootstrap/ask/prove-loop HTTP path: passed. Readiness advanced from
  3 pass / 6 fail to 5 pass / 4 fail without starting a runtime; the remaining
  failures were bridge contract, runtime health, calibration, and task
  execution. Every remediation action retained
  `physical_execution_allowed=false`.
- Governed command denial: passed for `Walk forward 0.5 metres now.` The
  message was classified `command-intent-review`; evaluate, dry-run, and
  approval evidence persisted, while execute returned HTTP 409
  `runtime-required`, with `dispatched=false` and `executed=false`.
- Durable recovery read: passed through `/api/moonrobo/session`
- Browser R1: passed refresh-ledger recovery, durable safe observation, and
  `operational-unproven` 3/6 evidence
- Browser R2: passed expected MoonClaw/runtime/calibration denial for the walk
  request; no physical execution occurred
- Browser R3: ledger refresh passed; a desktop-host process restart was not
  exercised
- Browser evidence:
  [`operational-unproven.png`](../../_build/ui-to-ui/2026-07-31-consolidated/operational-unproven.png)
  and
  [`runtime-calibration-denial.png`](../../_build/ui-to-ui/2026-07-31-consolidated/runtime-calibration-denial.png)
- Readiness/denial HTTP contracts: passed consolidated qualification
- MoonMold ingestion package: passed targeted MoonBit qualification, while the
  UI and vocabulary gaps below remain
- Live hardware/SDK/bridge: not tested
- Physical movement: deliberately not performed
