# Raw torque source and preload shadow, 23 November 2026

The intermittent zeros originate at or before the E1's status publisher. They
are not introduced by the host decoder, duplicate suppression or JSON export.
The January SDK and live DDS inventory do not provide a separate active-command
readback. A reliable powered takeover remains unqualified. This pass connects
an explicitly unqualified preload candidate to both hold and genuine actor
**shadow**, without creating motor or mode command publishers.

## Raw-packet evidence

`scripts/audit_e1_torque_capture.mbtx` independently reads Ethernet pcap,
IPv4/UDP, RTPS DATA and January XCDR1 motor records without the SDK or C decoder.
It checks 24 ordered IDs/errors and compares position, velocity and torque
doubles bit-for-bit to decoded status. Duplicate sequences must have identical
complete payloads; decoded sequences must occur exactly once. Tests cover a
known torque value, both endiannesses and signed zero.

| Saved capture | Unique samples | Exactly matching motor fields |
| --- | ---: | ---: |
| `holding-effort-hold-shadow-20261123-1` | 13,897 | 1,000,584 |
| `holding-effort-actor-shadow-20261123-1` | 76,694 | 5,521,968 |
| New `reported-effort-actor-shadow-20261123-1` | 77,048 | 5,547,456 |

Motor 7 at sequence `3141516` contains torque bytes `0000000068900640`, encoding
`2.8205108642578125`. Sequence `3141517` contains eight zero bytes, with identical
position `-0.10357093811035156`, velocity `-0.013187408447265625` and temperature
`-5`. This is an exact transmitted zero, not display rounding or a field-offset
error. In the 40-second capture, all torque fields are zero in 13,336 packets;
other packets contain various subsets, including 180 with all 24 nonzero.
Temperature does not distinguish torque presence. This suggests source-side
population/refresh behavior, but does not identify a firmware race or prove
that every literal zero is invalid.

## January SDK and alternative sources

The delivered `Robot_status.hpp` defines plain `double tau`, initialized to
zero, without a validity flag, individual age or active PD command fields.
The `lowcontroller.cpp` callback forwards `state.tau()` unchanged, and
`get_joint_state()` copies that same buffer. The command buffer contains the
local SDK application's commands, not factory controller output. Vendor
`LowController::init` requests low mode and starts sending threads; it was not
used as a diagnostic.

Receive-only discovery found publications `Robot_Status_Topic`, `T_NLP_Msg`
and `T_Error_Msg`. Motor/control endpoints are subscriptions. No active motor
command or dedicated effort publisher was discovered. Inventory now preserves
endpoints whose dynamic type identifier is absent. No mode, motor, text or
parameter commands were sent, and the onboard computer was not accessed.

Changing the host SDK getter cannot recover a field already zero in the source
packet. A reliable source still requires a documented producer validity rule,
a qualified effort/active-command interface, or a separately authorized
physical identification procedure. The existing gain settings were not raised.

## Implemented shadow candidate

`MOONROBO_E1_REPORTED_EFFORT_SHADOW=1` enables only shadow `hold` or
`actor-elbows`. After one second of existing stationary validation, the owner
waits for a fresh packet with finite, nonzero reports for all twelve leg joints.
It stops without targets if none arrives within ten seconds. This availability
predicate is not a validity flag: an actual zero also makes it wait. It does
not replace zeros, take a conditional median, or carry forward old values.

Every proposal/report records `moonrobo.e1-reported-leg-effort-shadow.v1`,
`power_qualified:false`, the original sequence/arrival and raw q/qd/tau arrays.
Reserved record 23 is provenance only and is never used as an actuator effort.
Leg position targets, gains and desired velocities remain unchanged. At the
seed pose, the counterfactual uses the standard PD model:

```
tau_ff_shadow = reported_tau_at_seed + kd * measured_velocity_at_seed
```

This preserves the reported instantaneous effort under that model. The
feedforward is then frozen. Only elbow positions 3/14 receive constrained actor
changes; arm feedforward remains zero. Freshness, scheduling, model checks,
leg-drift and isolated-ankle handling retain their original limits.

The launcher rejects this mode before creating live endpoints. The owners
require shadow, and the independent sender rejects the hypothesis marker even
if a caller removes the shadow flag or zeros the torque fields. The default
powered path does not silently select the candidate. A nonzero packet does
not establish motor-side age, commanded effort, the firmware actuator equation
or effort limits, so the candidate cannot qualify physical takeover or handback.

## Validation tools and preparation

`audit_shadow_hold_effort.py RUN NEW_REPORT` checks a completed no-publisher
hold, all 24 fixed records and an exact seed match to saved telemetry.
`audit_actor_targets.py CONFIG TARGETS NEW_REPORT --status STATUS` checks the
same seed plus actual model sequence, input age, authority/filter/slew, 22
fixed records and exact elbow return. A status trace is mandatory for the new
hypothesis. Both auditors are offline and retain `powered_takeover_qualified:false`.

The coordinator stops feeding telemetry at the owner's terminal stop row,
before NPU teardown, avoiding further feeds to a closed owner. Passive capture
and post-stop observation continue. Aggregate pipe timing still includes NPU
startup/backlog draining and must not be described as active inference latency.
The preparation artifact preserves both shadow seeds and remains explicitly
unarmed. It cannot manufacture a successful powered hold or handback receipt.

## Completed shadow results

`reported-effort-hold-shadow-20261123-1` completed 1,000 ms with 87 proposal
heartbeats and 902 observed packets. The independent audit matched its seed to
the saved telemetry and verified all 24 complete records stayed fixed. Maximum
accepted leg variation was 0.0218566°; one left and one right-only ankle event
cleared under the existing guard. The left-hip seed reported 2.7472534 Nm and
the initial damping-compensated feedforward candidate was 2.7252712 Nm. These
are proposed counterfactual efforts, not forces applied to the E1.

`reported-effort-actor-shadow-20261123-1` completed 31,664 ms with 1,584 genuine
Ascend inference updates, including 1,177 policy updates, and 2,743 heartbeats.
The independent target audit passed: 22 full records stayed fixed and both
elbow targets returned exactly. Authority remained 25%. Inference took at most
3 ms, schedule lateness 5 ms, and kernel-input age at inference 4 ms. Its seed
sequence `3692647` matched saved q/qd/tau exactly. The model identity remained
`031c4f35c09b86233d4ae05a44fdf5b6942a327224b112f7bc043b53c59727c0`.

Both sessions recorded `command_writers_created:false`, successful planner,
decoder and sink exits, expected capture timeout 124, and no status/command
feed error. NPU preparation took 2,913 ms and teardown 1,818 ms. The session's
2,812 ms aggregate pipe-write maximum includes preparation, not a control tick;
the owner drained 127 startup packets before establishing fresh telemetry.

50 relevant native tests passed locally with warning denial; 27 owner/control
tests passed on `.191`, and both deployed owners and launchers built in native
release with warning denial. The raw-reader unit test passed. All 28
network-free Python admission/inventory/audit tests passed, including forged
capture, changed-leg record, zero torque, false qualification and attempted
promotion of the shadow hypothesis. No tests or thresholds were skipped or
relaxed to obtain these results.

Raw captures, target/status traces and audits remain in the named directories
under `/home/jiaanguo/lunakine-deployment-20261117/actor-elbows-20261121`.
Local report copies are in ignored `output/e1-torque-source-20261123/`.
`reported-effort-trial-preparation-20261123-1.json` retains
`ready_for_powered_takeover:false`. The software counterfactual is exercised;
the requested reliable holding-effort source and physical takeover fix remain
unresolved under the read-only constraint.
