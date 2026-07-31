# Cross-product governed physical job

Last reviewed: 2026-07-31
Scenario: plan a guarded robot-cell layout, model it, and request a robot
readiness/command decision without bypassing authority

## Intended product chain

```text
MoonProj plan proposal
  -> named plan review
  -> MoonMold editable + engineering representation
  -> named spatial review
  -> MoonRobo engineering ingestion
  -> MoonRobo live readiness
  -> MoonClaw command decision
  -> MoonRobo governed command ingress
  -> physical feedback
  -> MoonBook accepted outcome / Three-Gap learning
```

MoonFlow owns graph state, retries, handoffs, and receipts. MoonClaw is the only
agent runtime. MoonProj, MoonMold, and MoonRobo remain pack/product owners of
their domain rules. None creates another runtime.

## Use case

Goal:

> Prepare a guarded humanoid inspection cell, prove that the digital geometry
> and robot identity match, and request a 0.5 metre inspection walk only after
> named review and live runtime validation.

Acceptance:

- project scope, owners, budget envelope, dependencies, risks, and evidence are
  reviewable;
- the spatial model retains editable and engineering lineage;
- MoonRobo imports only the reviewed engineering child of the accepted editable
  parent;
- physical readiness proves bridge identity, authority, telemetry, emergency
  stop, and repeated validation;
- command and feedback receipts close the loop;
- failure at any gate prevents the later effect.

## Phase 1 — MoonProj plan

The plan request should define at least:

- `survey-cell` — collect floor, obstacle, robot, and safety-boundary evidence;
- `model-cell` — produce editable and engineering representations;
- `review-spatial-model` — named review of dimensions, coordinate frame, and
  unresolved gaps;
- `validate-runtime` — repeated MoonRobo runtime validation;
- `review-command` — named review of the bounded movement;
- `observe-feedback` — post-command telemetry and outcome.

Required acceptance gates:

- source-evidence integrity;
- budget and owner review;
- spatial lineage and known-loss review;
- robot/bridge identity match;
- physical runtime and emergency-stop readiness;
- command receipt and feedback closure.

The `moonproj/project.plan.prepare@0.1.0` result must remain
`pending_review`, with every authority effect false. A named human must accept
the plan through a future `/projects` artifact projection before MoonFlow
advances it.

Current UI truth: `/projects` shows portfolio/Gate state but does not yet render
or accept this exact durable plan artifact.

## Phase 2 — MoonMold spatial representation

The MoonMold request references the accepted plan artifact using a
workspace-relative path and digest. In the spatial operator:

1. Create `guarded-cell-layout`.
2. Add bounded cell, exclusion-zone, and inspection-waypoint objects.
3. Export `editable-source`.
4. Export `engineering`.
5. Inspect lineage, units, coordinate frame, known losses, backend
   qualification, and claim ceiling.
6. Record a named review bound to the exact operation receipt.

No manufacturing candidate, simulation asset, render, or mock backend output
may silently replace engineering truth.

## Phase 3 — MoonRobo ingestion and readiness

MoonRobo must verify:

- exact accepted editable-parent digest;
- lossless engineering transform;
- units, coordinate system, up axis, and handedness;
- MoonRobo is an intended consumer and not forbidden;
- digital-artifact claim ceiling;
- authority reference integrity;
- unresolved assumptions remain visible.

After import, the engineering artifact is still only a digital candidate. The
operator uses the cockpit to bootstrap non-physical state, inspect readiness,
and prove the loop. Physical command ingress remains blocked until live runtime
validation passes.

## Phase 4 — governed command and feedback

The operator asks in MoonRobo:

```text
Using the accepted guarded-cell plan and reviewed engineering model, prepare a
0.5 metre inspection walk. Do not dispatch unless live readiness is complete.
```

Expected call chain:

```text
Rabbita task message
  -> MoonRobo durable task-message record
  -> MoonClaw robot routine
  -> MoonRobo context/readiness
  -> MoonClaw bounded command decision
  -> MoonRobo gateway command ingress
  -> live runtime validation
  -> bridge execution receipt
  -> telemetry feedback binding
  -> MoonBook outcome evidence
```

If live readiness is incomplete, the correct output is a denied command plus
the next safe remediation route.

## Negative and recovery cases

| Failure | Required behavior | Recovery |
| --- | --- | --- |
| Plan lacks named review | MoonFlow stops before spatial work | Record review over exact plan digest |
| Plan evidence changes | MoonProj reconciliation conflicts | Issue a new plan/attempt version |
| Mock model presented as Blender | MoonMold denies/makes evidence class visible | Qualify real provider separately |
| Spatial parent digest stale | MoonRobo ingestion denies | Re-export from accepted editable parent |
| Engineering transform is lossy | MoonRobo ingestion denies | Resolve losses and create new reviewed child |
| Robot is forbidden consumer | MoonRobo ingestion denies | Correct reviewed consumer policy |
| Runtime or bridge absent | Command remains blocked | Start supervised runtime, validate repeatedly |
| Robot/bridge identity mismatch | Readiness fails | Correct mapping and revalidate |
| Restart after durable attempt | Reconcile; do not duplicate effect | Reload same IDs and receipts |
| Missing post-command feedback | Outcome remains unverified | Bind matching telemetry; never infer success |

## Current executable truth

| Segment | Status |
| --- | --- |
| MoonProj typed plan capability and recovery | implemented at adapter boundary |
| MoonProj plan artifact in `/projects` UI | missing |
| MoonMold first-class operator and named review | implemented |
| MoonMold operator output accepted directly by MoonRobo | composite contract, lineage, authority, spatial, consumer-policy, and vocabulary gap |
| MoonRobo portable engineering validator | implemented at package boundary |
| MoonRobo cockpit import of portable engineering envelope | missing |
| MoonRobo readiness and governed command UI | implemented |
| Live hardware execution | external, not qualified here |

Because the two middle UI handoffs are missing, the complete physical job is
**designed but not UI-to-UI qualified**. Tests may prove each existing
contract, but must not describe the whole chain as operational until:

1. `/projects` renders and reviews the exact MoonProj plan artifact;
2. MoonMold and MoonRobo share one versioned portable engineering envelope or
   a reviewed pack-owned exporter/translator that preserves exact parent/child
   identity and digest, spatial conventions, authority, consumer policy,
   assumptions, unresolved gaps, and declared losses;
3. the MoonRobo cockpit exposes that ingestion with evidence and denial state.

## Consolidated qualification evidence

The 2026-07-31 contract pass established the following without invoking a
physical effect:

- MoonProj published the single
  `moonproj/project.plan.prepare@0.1.0` capability over
  `moonflow.adapter.v2`; targeted execute/reconcile and project-plan tests
  passed. Its Rabbita production bundle also built, but the plan artifact is
  not projected in the UI.
- MoonMold created a governed digital model, exported `editable-source` and
  `engineering` artifacts, reconciled the exact attempt, and attached a named
  review. Live Blender failed closed as unqualified and every receipt retained
  `physical_authority=false`.
- Direct artifact inspection confirmed that MoonMold emits a flat artifact
  with representation values `editable-source` and `engineering`, while
  MoonRobo requires a composite manifest/transform envelope with
  `editable-authoring-model` and `engineering-model`, exact parent/child
  identities and digests, spatial conventions, authority, intended/forbidden
  consumers, assumptions, unresolved gaps, and declared losses.
- MoonRobo's three portable-ingestion package tests passed, including stale
  parent and lossy/wrong-consumer denials. Its cockpit has no matching import
  route.
- MoonRobo safely bootstrapped MoonBook/tool evidence and persisted a command
  review, but runtime execution returned `runtime-required`. Readiness stayed
  blocked, no task execution existed, and no physical command was dispatched.

This is a qualified set of product boundaries plus a documented integration
gap, not an end-to-end physical-job acceptance.

The consolidated browser pass also verified each available edge honestly:
MoonProj rendered its portfolio/Gate projections and denied an unavailable
formal-task gateway; MoonMold recovered, reconciled, and attached named review
while exposing its digital-only authority; MoonRobo restored the task ledger
and denied command progress at MoonClaw/runtime/calibration. No browser could
exercise the missing plan-artifact review or portable spatial-ingestion edges,
and no physical execution occurred.

## Operator checklist after those gaps close

1. Open MoonProj `/projects`; inspect and accept the exact plan.
2. Follow the MoonFlow handoff to MoonMold; create/export/review geometry.
3. Follow the receipt-bound handoff to MoonRobo; import engineering artifact.
4. Confirm parent digest and spatial conventions.
5. Bootstrap only non-physical readiness.
6. Qualify runtime, bridge contract, telemetry, and emergency stop.
7. Ask MoonClaw to prepare the bounded command.
8. Review the command and dispatch once.
9. Bind physical feedback and inspect the execution proof.
10. Let MoonBook Bookkeeper accept the outcome and propose Three-Gap learning;
    it must not self-update policy or physical authority.
