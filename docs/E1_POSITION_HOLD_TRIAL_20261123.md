# Finite position-feedback hold commissioning, 23 November 2026

Status: **the real hold attempt failed the unchanged leg-drift guard** after
approximately 0.095 seconds of transmission. It did not complete the requested
one-second hold. The operator subsequently reported the E1 steady and the
handheld responding normally. No elbow movement was commanded and no second
powered attempt was made. Native, isolated DDS and fresh telemetry shadow tests
had passed before this single powered attempt.

The earlier [fifteen-second shadow](E1_POSITION_HOLD_SHADOW_20261123.md) remains
receive-only. Its entry point still rejects live admission. The separate
[`position-hold-trial.json`](../deploy/e1/position-hold-trial.json) requests one
second of commissioning, retains `power_qualified:false`, and pins the SHA-256
of the earlier independent shadow audit. Before creating DDS participants,
the sender checks that exact digest and successful receive-only provenance.

## Trial scope and protections

Feedback settings must exactly match the prior shadow: SDK position gain 50
and damping, integral gain 50, the existing one-degree relative leg guard and
the same effort amplitude/slew limits. No tuning or nominal-zero substitutions
are admitted. The existing measured-pose profile still binds the persistent
negative right-knee raw value. All 24 position references stay fixed, including
both elbows. Only the 12 leg feedforward fields can change according to the
independently recomputed position integral; reported torque is not an input.

The numeric state is shared by separate shadow and trial wrappers. Shadow
powered-use rejection remains. The finite wrapper additionally latches on its
one-second deadline. The planner stops normally at one second; the sender
retains its 1.25-second outer hold timeout. Existing freshness, sequence, peer,
gains, motor-health and stationary/glitch checks remain. Any guard stop ends
the attempt; there is no automatic retry or elbow stage.

`MOONROBO_E1_POSITION_HOLD_TRIAL` selects the request;
`MOONROBO_E1_POSITION_HOLD_SHADOW_AUDIT` supplies its pinned audit. Launcher and
coordinator restrict it to hold, rejecting simultaneous shadow/reported-effort
flags. Preview through `shadow hold`; only a separately requested `live hold`
creates command writers. The default transport still rejects adaptive effort
without explicit trial admission and rejects every shadow-marked target.
Trial metadata cannot disappear or change. Its receipt cannot authorize actor
takeover, which remains a separate uncommissioned transition.

## Completed checks

- 58 relevant native tests passed locally with `--deny-warn --warn-list +73`.
- 35 owner/adapter/control native tests, release builds and 35 Python tests
  passed on `.191`.
- In a Linux namespace containing only `lo`, isolated run
  `moonrobo/deploy/e1/runs/position-hold-1795417612683` received 482 frames /
  11,568 motor records, mode 2 once, action 11 and zero axes. A test-only
  0.001-rad hip displacement produced 0.04005000000000003 Nm corrective bias.
  All 24 positions and all velocity/gain fields stayed fixed. Both writers
  disconnected after approximately 0.999 seconds. Both test endpoints enforce
  the loopback-only namespace before creating participants.
- Fresh E1 telemetry shadow `position-trial-shadow-20261123-1` completed in
  1,002 ms with 88 proposals and 700 planner packets; its complete passive
  capture contains 13,870 records. All 24 references stayed fixed. Maximum
  proposed bias was 0.018146018657684324 Nm, and largest accepted measured leg
  variation was 0.021856605344040804 degrees. Six left/bilateral and one
  right-only isolated ankle events cleared. Every input/calculation matched
  the saved capture. All process exits were zero except expected passive
  capture timeout 124; both feed errors were null. No command writers existed.

Named paths are relative to
`/home/jiaanguo/lunakine-deployment-20261117/actor-elbows-20261121` on `.191`.

## Real attempt and post-disconnect verification

The operator confirmed current Walk mode, both feet planted, crane bearing
weight, a clear area and an operator at the paired handheld emergency disable.
A new complete preflight passed. Run `position-trial-powered-hold-20261123-1`
then requested one `live hold` with the explicit request and evidence.

| Finding | Measured result |
| --- | --- |
| Stop reason | Stationary joint outside tolerance, SDK 7 / left hip pitch |
| Actual command transmission | 47 frames / 1,128 records over 94.853 ms on capture |
| Planner proposals | 9; all 24 position references unchanged |
| Wire protocol | Mode 2 once, action 11, zero axes |
| Position-feedback calculation | Independently passed against captured inputs |
| Maximum proposed leg bias | 0.03417276338577271 Nm |
| Wire/proposal identity | All 47 frames matched identical fresh admitted proposals |
| Left hip raw offset in active measurement window | Maximum 1.0272604511699177 degrees |
| First hip offset over 1 degree | 96.477 ms from first target reference |
| Maximum hip offset in active plus post-stop trace | -2.9069285107574268 degrees at 460.72 ms, after sending stopped |
| Velocity integral at that peak | -3.0168221796787362 degrees; residual 0.10989366892130947 degrees |
| Raw packets over 1 degree | 299; last at 954.43 ms |
| Endpoint cleanup | Sender reports participant deleted; no further commands |
| Operator observation | “平稳”; handheld “正常” |

The gradual raw position changes and broadly matching velocity integral support
real settling rather than an isolated decoding spike. The integral correction
was computed and sent, but this run did not maintain the pose within the existing
bound. Wire verification does not prove the firmware applied the requested
effort. Unknown initial support effort remains a plausible cause, not a
confirmed firmware diagnosis. No gain change, threshold relaxation, zero-offset
change or powered retry followed.

Audit proposals and raw inputs with `audit_shadow_hold_effort.py --trial RUN
PROFILE SHADOW_AUDIT NEW_REPORT`; this also records partial failed trials
without calling them completed holds. Decode captured commands with
`e1_command_packets.py WIRE READY NEW_REPORT --position-hold-trial PROFILE`.
Every wire frame must match an identical fresh admitted proposal, including
its feedforward. `measure_trial.mbtx` reports active/post-disconnect raw
motion; isolated ankle spikes and reserved record 23 need separate treatment.

The operator supplied steadiness and handheld-response observations after the
stop. They are recorded as operator evidence, separately from the packet audit;
telemetry cannot establish factory ownership. Because holding failed, no
successful-hold handback receipt was issued and actor takeover remains blocked.
The [compact evidence record](evidence/e1-position-hold-trial-20261123.json)
retains the result and raw-artifact hashes.

Position error cannot reveal unknown factory preload at zero error. This
finite commissioning request does not claim that its initial gains prevent
the earlier hip settling.
