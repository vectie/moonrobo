# Holding transition investigation, 23 November 2026

The robot's powered holding transition is **not yet fixed or qualified**. This
pass fixed a torque-visibility omission, implemented and tested an effort-matching
calculation, and repeated receive-only hold and real-inference actor shadow on
`.191`. No motor or mode commands were sent in this pass. The next physical
hold and elbow trial remain unarmed because the previous controller's active
holding effort is not established.

The [raw-packet follow-up](E1_TORQUE_SOURCE_20261123.md) locates the zeros in
the transmitted status records and implements an explicitly unqualified
reported-effort shadow candidate. It does not qualify the powered transition.

## Gain sources checked

The installed 3.1 SDK standing example uses `kp=50`, `kd=5`, with `kd=1` for the
four ankles. These match `Sample::stand_candidate`; the generic standing gains
were not accidentally swapped or omitted. The sample intentionally begins its
standing interpolation at measured positions, but that is not evidence of
effort continuity from a loaded factory Walk controller.

The older delivery SDK is also present on `.191` at
`/home/jiaanguo/lunakine-deployment-20261117/delivery-sdk-check-dsiTNsxn/noetix_sdk_e1-main`.
Its `config/ning_user.yaml` specifies hip/knee stiffness 140 for the user
configuration and 120 for `stiffnessRun`, hip yaw/roll 80, ankle pitch 20, and
different arm gains. Its `handleStandMode` instead uses the standing routine's
50/5 and ankle damping 1. Its policy handler uses model-dependent gains and
positions. These are distinct sources, not interchangeable definitions of the
currently active factory gains. The old YAML covers 10/18-action configurations
and does not supply a complete commissioned 23-motor hold.

The saved SDK headers and January guide expose position, velocity and reported
torque, but no active desired targets, gains or per-motor torque-valid flag.
The full-array motor command interface does not establish independent elbow
ownership while factory leg control continues. No higher gain or unverified
position offset was selected to overcome the previous hip drift.

The current vendor [standing/policy example](https://github.com/Noetix-Robotics/noetix_sdk_e1/blob/main/examples/cpp/example_low.cpp)
was checked as supplementary source evidence. It does not establish this older
unit's current factory settings. The vendor documentation URL presently returns
an nginx placeholder, so the already-delivered guides and local source remain
the usable reference.

## Torque visibility fix and actual measurements

`e1_status_packets.py` decoded torque in its C buffer but dropped it from the
shadow packet JSON. It now preserves all 24 reported torque fields as
`packet.tau`, with finite-value validation. Existing MoonBit status readers
continue to consume their original fields. The receive-only `preflight.py`
now also records minima, maxima and nonzero counts across the entire sampling
window; a last-frame snapshot was insufficient to characterize this signal.

The fresh preflight collected 693 complete samples. The subsequent 40-second
receive-only hold session retained 13,897 unique decoded samples:

| Finding | Measurement |
| --- | --- |
| Entire 24-record torque array zero | 13,336 packets |
| Left hip 7 nonzero torque | 316 of 13,897 packets |
| Left hip nonzero range | 2.5274658 to 3.0402985 Nm |
| Left hip nonzero-only median | 2.8205109 Nm |
| Left hip mean including zeros | 0.0636604 Nm |
| Maximum gap between nonzero left-hip reports | 633.491 ms |
| Right hip 18 nonzero-only median | 0.7692261 Nm |
| Reserved record 23 | Intermittently reports torque 90; excluded from physical-joint interpretation |

The dynamic DDS preflight reader and captured-packet decoder both observed
intermittent nonzero values. This corrects the implication from earlier
single-frame observations that reported torque was always zero. The conditional
median and whole-stream mean differ by over forty times; neither can be adopted
as a qualified holding command without knowing whether zero means a real value
or an absent update. Nonzero reports also lack an independent per-field age.
The SDK source simply forwards `state.tau()` and does not resolve this ambiguity.

The measurements support investigating lost preload, but do not prove the
cause of the earlier 2.64° hip settling. Reported torque is not automatically the
factory controller's commanded effort, and its sign, units and motor-side
filtering have not been independently qualified for this unit.

## Effort-matching implementation and limits

The new `Sample::effort_matched_candidate` implements the standard PD-plus-
feedforward transition calculation:

```
u_before = kp_old * (q_des_old - q) + kd_old * (qd_des_old - qd) + tau_ff_old
q_des_new = q
qd_des_new = 0
tau_ff_new = u_before + kd_new * qd
```

At the captured state, this gives `u_after = u_before` under that actuator
model, while all physical position targets remain at the measured pose. It
accounts for damping and holds the reserved record at zero position/gain/torque.
It rejects absent, invalid or nonfinite active commands and overflow. Tests
include a loaded hold where the previous measured-position/zero-feedforward
candidate would discard more than 3 Nm of preload.

This method requires a **trustworthy, fresh active command snapshot**. It does
not accept raw motor torque as that snapshot. It is a pure candidate calculation,
not connected to the live sender. Existing transport admission still rejects
nonzero feedforward torque. No torque feedforward, gain change, inferred zero,
median, stale last-nonzero hold or disturbance estimate was sent to the E1.
Numerical effort continuity does not by itself verify the firmware model,
torque limits, physical leg response or handback behavior.

## Repeated shadow and prepared physical sequence

`holding-effort-hold-shadow-20261123-1` completed its one-second hold shadow with
all 24 targets fixed. `holding-effort-actor-shadow-20261123-1` completed the
existing genuine Ascend FP32 actor: 31,623 ms, 1,582 inference updates, including
1,177 policy updates; inference at most 3 ms, lateness 5 ms and input age 4 ms.
Only elbow slots 3/14 were proposed to move, all 22 other complete records stayed
fixed, and both elbow targets returned exactly. These tests used the existing
zero-feedforward proposal path with the newly visible torque stream. They are
**not** a live test of a compensated holding controller.

The actor session also retained a status-feed broken-pipe diagnostic during
shutdown after the active proposal sequence completed. The coordinator's
aggregate feed timing includes that close phase and reached about 2.96 seconds;
it must not be presented as active inference latency. The active planner and
independent target audit passed their original deadlines. The preparation
artifact retains the full session diagnostics rather than calling the archive
unconditionally clean.

`deploy/e1/prepare_hold_trial.mbtx` checks the completed shadow receipts, pins
the January SDK source/config hashes, and writes the reviewable next sequence.
Its artifact explicitly says `ready_for_powered_takeover:false` and identifies
the missing active-effort information. It does not create a handback receipt,
alter a profile to authorize torque or start a controller.

The remaining sequence is:

1. Establish fresh active targets/gains/feedforward, or independently qualify
   a holding-effort signal including its zero/validity/age semantics, sign and
   allowed limits. Confirm the actuator equation and transfer/handback behavior.
2. Connect that source to the effort-matched candidate; validate both the owner
   and independent sender, then replay and live-shadow it. Do not use a gradual
   ramp from zero effort as a substitute for matching the existing effort.
3. With current physical setup confirmed, complete a new finite hold with no
   elbow movement, inspect actual leg response and observe handback.
4. Only after that successful hold and genuine handback receipt, execute the
   existing 25%-authority actor on elbows 3/14, freezing the other complete
   motor records, then return and audit.

The relevant missing vendor information is the factory controller's active
effort/target interface, the intermittent torque field's update semantics, and
whether the firmware provides a supported transfer that preserves leg holding.
The unit's factory computer was not accessed or modified.

## Verification and artifacts

49 relevant native tests passed locally with `--deny-warn --warn-list +73`;
26 owner/adapter/control tests passed on `.191`. The 22 network-free Python
transport/decoder tests passed on `.191`. Regression checks cover torque field
stride and validation, numerical preload/damping continuity, rejection of an
unknown active command, and the existing sustained-leg-drift guard.

Remote reports and raw captures remain in the two named shadow directories
under `/home/jiaanguo/lunakine-deployment-20261117/actor-elbows-20261121`.
`scripts/audit_e1_hold_effort.mbtx` reproduces the torque-distribution audit from
saved decoded status without a robot connection. The prior powered stop remains
documented in [the commissioning record](E1_CURRENT_POSE_COMMISSIONING_20261123.md).
