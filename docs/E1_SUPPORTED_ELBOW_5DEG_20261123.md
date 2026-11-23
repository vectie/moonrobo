# Supported elbow with the operator's 5° envelope, 23 November 2026

The operator explicitly allowed **all joints to operate within a five-degree
envelope**. The new, separate v2 profile completed an initial real E1 commissioning
gesture from `.191` and an explicitly requested repeat. Raw telemetry from the
initial run confirms a 4.655566221307411° left-elbow
fold. All 12 leg position targets stayed fixed; maximum accepted measured leg
deviation was 3.125549205711195°, within the requested envelope. The operator
did not notice the first gesture and requested a repeat, then reported
“没问题”. The repeat also completed, with a 4.611853010619329° measured fold and
2.9288397576148277° maximum accepted leg deviation.

This is a deterministic 5° elbow reference, not trained-policy inference or a
qualification of autonomous standing. The earlier
[1° hold](E1_POSITION_HOLD_TRIAL_20261123.md) and
[3° leg-only trial](E1_SUPPORTED_ELBOW_20261123.md) retain their original stopped
results. They are not retroactively called successful.

## Explicit configuration

[`supported-elbow-5deg.json`](../deploy/e1/supported-elbow-5deg.json) uses
`moonrobo.e1-supported-elbow.v2`. It specifies 5° for stationary non-target
joints, 5° for leg feedback error, and 5° for the moving elbow's following error
relative to its preceding target. These are feedback error allowances, not
instructions to move the other joints. The only changing position reference
is left elbow SDK slot 3, folding 5° and returning over 15 seconds.

The trial starts with three seconds of continuous holding and ends with 500 ms
at the original elbow target. It retains the existing gains, zero velocity
references, bounded/slew-limited leg position-integral correction, joint-range
checks, motor errors, packet continuity, 40 ms freshness/watchdog and 19-second
outer transport limit. Ankle jump detection and 6 ms recovery remain independent
of the larger drift envelope. The default hold/actor guards were not changed.
SDK slot 23 remains reserved with zero position/gain/feedforward.

The v1 profile remains available as a historical artifact for Python audits;
the new supported owner requires v2's explicit fields. Its fresh shadow proof
is bound to profile SHA-256
`739579e0d822a954cce3fa5713dcd8bf0ad10964b4fd299e1f504ba1ddd1afb9`.
Changing a profile cannot reuse a prior differently configured shadow receipt.

## Validation and real result

65 relevant native tests passed locally with `--deny-warn --warn-list +73`.
39 native owner/adapter/control tests, release builds and 39 Python tests passed
on `.191`. Regression cases accept 4.5° only through explicit supported
admission, reject 5.1°, preserve default one-degree behavior and preserve the
old hold's strict admission. The elbow following check is still bounded.

`supported-elbow-5deg-shadow-20261123-1` completed the entire reference with
1,594 proposals and exact target return, no command writers, and an independent
match of every input/calculation to saved status. The isolated loopback run
`moonrobo/deploy/e1/runs/supported-elbow-1795421276257` checked 8,936 frames /
214,464 records and the full return, including the injected passive startup
gap and bounded feedforward saturation.

Actual run: `supported-elbow-5deg-powered-20261123-1`.

| Evidence | Result |
| --- | --- |
| Completed active sequence | 18,501 ms, reference frame 750, 1,589 proposals |
| Actual transmission | 8,925 frames / 214,200 motor records, 18,498.088 ms |
| Protocol | Mode 2 once, action 11, zero axes |
| Commanded left elbow | -5° peak offset, exact return to starting target |
| Measured left-elbow peak offset | -4.655566221307411° |
| Measured left elbow at end of sending | -1.3333075674998491° from start |
| Measured left elbow 3 s after disconnect | -0.04371321068808161° from start |
| Largest accepted leg displacement | 3.125549205711195°; leg targets unchanged |
| Largest other stationary-arm raw displacement | 1.682958611491142°, left shoulder roll |
| Maximum commanded leg bias | 7.5 Nm, reached the configured cap |
| Cleared ankle events | 55 left/bilateral, 20 right-only |
| Capture | 13,841 decoded samples; 1,034 post-disconnect samples in the session observation |
| Process exits | Planner/sender/observer/decoder all zero; passive capture expected 124 |
| Feed errors | None |
| Endpoint cleanup | Sender reports participant deleted |

The proposal/raw-input audit passed. All 8,925 captured command frames matched
identical fresh admitted proposals. Only left-elbow position references moved;
all positions returned exactly as **targets**. Actual elbow return was not
exact when the sender closed: the 1.33° residual reduced to approximately 0.04°
over the following three seconds. Therefore do not describe this as exact
controller tracking at disconnect. Likewise, fixed leg targets did not mean
the legs were physically motionless: approximately 3.13° settling occurred.

The leg correction reached its configured command cap. These records establish
this bounded gesture's transmission and measured motion; they do not identify
the firmware's effort scaling or prove the preload/precision-holding issue
resolved. A second gesture was explicitly requested by the operator; no
automatic repeat occurred. The native profile
continues to say `power_qualified:false`, and this stage does not issue the
ordinary hold receipt required for actor takeover.

## Explicitly requested repeat

The operator replied “再来一遍，没注意。” and then “没问题”. The identical v2
profile ran once more as `supported-elbow-5deg-powered-20261123-2`, after a fresh
preflight, with no parameter change. It completed in 18,501 ms: 1,592 proposals,
8,923 wire frames / 214,152 records, and an exact position-target return. Every
frame and every input/calculation passed the independent audits.

The measured left-elbow fold was 4.611853010619329°. Its residual at sender close
was 1.2895943568117674°; the last raw reading in the three-second post-disconnect
window exactly matched the initial reading. Maximum accepted leg deviation was
2.9288397576148277°, with leg position references still fixed. All process exits
and feed diagnostics were clean. The operator's “没问题” is retained as their
observation, not converted into a firmware ownership acknowledgement or an
ordinary hold/actor qualification receipt. Both command publishers closed and
no additional repetition was queued.

Full artifacts remain under
`/home/jiaanguo/lunakine-deployment-20261117/actor-elbows-20261121` on `.191`.
The [compact evidence record](evidence/e1-supported-elbow-5deg-20261123.json)
pins the captures, audits, measurements and operator-observation status.
