# Position-feedback hold shadow, 23 November 2026

The position-only candidate completed a 15-second receive-only test on `.191`.
It does not depend on reported motor torque. All 24 commanded position records
stayed fixed. **The physical takeover is still unqualified:** no mode or motor
commands were sent, and factory control remained responsible for the measured
pose throughout this test.

This is an alternative investigation to the
[active-effort matching path](E1_HOLDING_EFFORT_20261123.md). It does not require
resolving the intermittent torque field before running shadow calculations.
It also does not establish instantaneous effort continuity at takeover.

## Calculation and admission

After one second of accepted stationary telemetry, capture all 23 physical
joint positions. Reserved SDK record 23 keeps position/gain/feedforward zero
and damping 5. Keep all position references, zero velocity references and SDK
standing gains fixed. At each approximately 10 ms proposal heartbeat:

```
error[i] = captured_position[i] - measured_position[i]
requested[i] = previous_bias[i] + Ki * error[i] * source_dt_seconds
amplitude_limited[i] = clamp(requested[i], -bias_limit[i], bias_limit[i])
bias[i] = previous_bias[i] + clamp(
    amplitude_limited[i] - previous_bias[i],
    -slew_limit[i] * source_dt_seconds,
     slew_limit[i] * source_dt_seconds)
```

Only leg slots 5–10 and 16–21 receive this proposed feedforward bias. The applied,
bounded bias is the entire integral state, so amplitude/rate limiting cannot
hide an accumulating unbounded integral. Reversing position error immediately
unwinds the applied bias. Output limiting and anti-windup are standard control
implementation concerns; see [MathWorks' explanation](https://www.mathworks.com/help/slcontrol/ug/improve-pid-to-handle-plant-constraints.html).
The particular experiment here is implemented and tested independently in
MoonBit; it is not a qualified model of the E1's dynamics.

The core API accepts positions, velocities, motor errors and clocks, with **no
torque-readback parameter**. The hold owner's position-only parser also ignores
the optional torque field. Raw packet captures continue preserving that field;
wire-schema, finite-value and motor-health checks are not weakened.

The existing stationary/glitch detector still processes every adjacent raw
packet. A provisional ankle sample never updates the integrator. Sustained
relative leg drift still stops at the existing one-degree bound. Accepted
integrator samples additionally require monotonic source/receipt clocks, gaps
and host age at most 40 ms, and complete error-free ordered motor records.
Faults latch. Source time is compared only with source time; no host/source
clock offset is assumed.

## Explicit experimental parameters

The versioned [configuration](../deploy/e1/position-hold-shadow.json) specifies
`power_qualified:false`; there are no implicit tuning defaults.

| Parameter | Shadow setting and rationale |
| --- | --- |
| Existing position gain | 50 Nm/rad; unchanged SDK standing candidate |
| Integral gain | 50 Nm/(rad·s), an initial one-second integral time relative to that gain |
| Bias caps | Hip yaw/roll 4.5 Nm, hip pitch/knee 7.5 Nm, ankles 3.5 Nm |
| Bias slew caps | The corresponding cap per second |
| Other joints and reserved record | Zero adaptive bias and slew budget |
| Relative leg error | Existing maximum 1°; no relaxation |
| Active shadow hold | 15 seconds; existing powered hold duration unchanged |

The effort caps are 5% of the documented peak ceilings and bound a numerical
experiment. They are **not** commissioned continuous-torque limits or a claim
that these parameters can prevent the previous settling. No gain increase,
knee-zero correction, position-reference adjustment, torque median or last
nonzero torque seed is used. The measured-pose profile still preserves the
persistent negative right-knee raw value exactly.

Set `MOONROBO_E1_POSITION_HOLD_SHADOW` to the configuration path only with the
existing `shadow hold` launcher. It is mutually exclusive with reported-effort
shadow mode. Both launcher and coordinator reject it for live or actor stages
before creating command publishers. The independent sender rejects the
`position_hold_shadow` marker even if someone removes the shadow flag and
zeros every torque. The actor proposal path has not yet been modified to use
this experimental controller.

## Live result and independent audit

Run directory on `.191`:
`/home/jiaanguo/lunakine-deployment-20261117/actor-elbows-20261121/position-hold-shadow-20261123-1`.

| Evidence | Result |
| --- | --- |
| Network link | `eno1` UP, `192.168.55.101/24`; fresh complete E1 discovery passed |
| Active hold | 15,000 ms, 1,299 proposal heartbeats, 5,514 planner packets |
| Entire receive-only capture | 13,925 decoded records |
| Fixed position records | All 24; proposed position changes exactly zero |
| Fully fixed motor records | 12; the other 12 retain fixed positions/gains/velocities while effort may adapt |
| Maximum proposed absolute bias | 0.059800868129730164 Nm |
| Largest accepted measured leg variation | 0.4515415775856035°; this is factory-controlled feedback, not target movement |
| Cleared isolated ankle samples | 50 left/bilateral, 14 right-only |
| Planner/sink/observer/decoder exits | All zero; finite passive capture ended with expected timeout 124 |
| Status/command feed errors | None |
| Maximum kernel-arrival-to-planner-feed interval | 5 ms |
| Mode or motor command publishers | None |

`audit_shadow_hold_effort.py` independently recomputed all 1,299 proposals,
checked all 24 fixed references and gains, and matched every input's exact
sequence, source/arrival clocks, positions and velocities against saved raw
status. Its calculation never consumes reported torque. Audit passed. Compact
receipts are retained in [the evidence record](evidence/e1-position-hold-shadow-20261123.json);
full raw captures and target records remain in the named remote run directory.

Validation passed: 56 relevant native tests locally with
`--deny-warn --warn-list +73`; 33 owner/adapter/control native tests on `.191`;
31 Python validation/transport/decoder tests on `.191`; and release builds of
the owners, launcher and coordinator. Native regressions cover corrective sign,
fixed references, amplitude/slew limits, reversal without hidden windup, stale
or malformed inputs, live rejection, latched stops, and a toy loaded-joint
simulation. The small toy disturbance converges; a larger disturbance still
trips the existing drift bound. That simulation is not E1 identification.

## What remains unresolved

Position-only feedback can react to an error without trustworthy torque
readback. At zero error, however, it cannot identify an unknown existing load
or the factory controller's preload. Starting the bias at zero therefore does
not prove a bumpless transition. During this shadow test, factory control
produced the feedback; the unexecuted bias did not cause or stabilize it.

The earlier continuous hip settling remains real evidence to explain, not a
sensor spike to suppress. No claim is made that these initial parameters would
have prevented the earlier one-degree stop at roughly 93 ms. Physical response,
adequate gain/effort limits and handback remain to be commissioned separately
before combining this candidate with the elbow actor. No prepared powered-test
receipt has been promoted by this shadow result.
