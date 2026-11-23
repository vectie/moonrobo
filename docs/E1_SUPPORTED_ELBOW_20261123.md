# Supported elbow commissioning, 23 November 2026

The requested elbow gesture has **not yet executed on the E1**. The operator
accepted approximately three degrees of temporary leg settling while the crane
bears weight. A separate commissioning profile was implemented and validated;
the actual attempt then stopped during its initial hold because the left
shoulder roll exceeded the unchanged non-leg one-degree bound. Acceptance of a
three-degree bound for other non-target joints, and current physical/handheld
observations after that stop, are pending. No further real commands are queued.

## Explicit scope

[`supported-elbow.json`](../deploy/e1/supported-elbow.json) is a separate,
unqualified commissioning request. It keeps every leg position reference fixed
and retains the prior feedback gains, amplitude limits, slew limits and motor
health/freshness checks. It permits at most three degrees of relative leg
deviation. The ordinary hold and actor paths keep their original one-degree
settings. All non-target non-leg joints also still use one degree. The elbow's
physical following check remains one degree from its preceding target.

This is deterministic reference commissioning, not trained-policy inference:
three seconds of holding, the existing fifteen-second five-degree left-elbow
fold/return, then 500 ms at the starting elbow target. It is one continuous
owner and position-integral state, without a second takeover between hold and
gesture. The independent sender caps total transmission at 19 seconds and
checks every proposed reference, position-integral output, sequence, profile,
clock and motor record. Only SDK slot 3 can change position targets. A matching
completed read-only shadow audit, pinned to the exact profile file SHA-256,
is required before command participants are created.

The three-degree leg envelope does not suppress abrupt ankle packets. The
existing one-degree jump signature and six-millisecond recovery checks remain
separate from allowable gradual settling. Tests cover all fifteen ankle
subsets, including isolated pitch spikes below three degrees, default guard
behavior and sustained drift above the explicit supported bound.

## Qualification before the actual attempt

63 relevant native tests passed locally with `--deny-warn --warn-list +73`;
38 owner/adapter/control native tests, release builds and 38 Python tests passed
on `.191`.

Run `supported-elbow-shadow-20261123-1` passed the full 18.5-second reference
and independent raw-input audit: 1,599 proposals, all 12 leg position records
fixed, reference frame 750, exact position-target return, maximum proposed
bias 0.4655149947826386 Nm, no mode/motor writers and clean process exits. Profile
SHA-256: `6ff0e02cfa0c104f32cb7a3179e4f28846b0fec31a8eec70cd1ceed27e8e0ab9`.

The complete owner and sender were also tested in a network namespace containing
only loopback. `moonrobo/deploy/e1/runs/supported-elbow-1795419369254` checked
8,934 wire frames and the complete five-degree return. A second isolated run,
`supported-elbow-1795419774551`, checked 8,938 frames / 214,512 motor records and
the exact return after a deliberately injected startup packet loss. All other
position references remained fixed and feedforward saturation stayed bounded.
These are software/transmission checks, not E1 motion qualification.

## Startup interruption and correction

`supported-elbow-powered-20261123-1` stopped before any actual command. Both
the transport receipt and independently decoded outbound capture show zero
motor frames and zero mode requests. Its saved stream contains one sequence
gap, 5371817 → 5371819, spanning 5.836280 ms of source time and 5.833 ms of host
receipt time. The strict adjacent-sequence check correctly rejected it.

The supported owner now reacquires a full stationary second after a fresh,
forward-only startup gap, with a ten-second overall startup limit. It cannot
reset a guard after arming, during pending ankle confirmation, on reversal or
on an input gap beyond 40 ms. The isolated injected-gap run requires exactly
one passive restart and still verifies the entire gesture. The existing active
continuity checks were not weakened. `audit_e1_stream_gaps.mbtx` reproduces the
gap evidence from saved status without opening a connection.

## Actual takeover result

`supported-elbow-powered-20261123-2` sent mode 2 once, action 11 and zero axes,
with 61 motor frames / 1,464 records over 123.564 ms. Every captured frame
matched an identical fresh admitted proposal; all 24 position targets were
still unchanged because the initial hold had not finished. No elbow fold
target was sent. Maximum proposed leg bias was 0.06193973375320434 Nm.

The native guard stopped at SDK 1, left shoulder roll. Its active-window raw
offset reached 1.0491170565139585 degrees; the subsequent three-second raw peak
was 1.682958611491142 degrees and its last offset was 0.021856605344040804
degrees. The active left-hip offset was 1.7048152168351827 degrees, within the
explicit leg allowance. The sender deleted its participant, and no retry
followed this powered stop. All post-stop observations remain separate from
proof of successful holding or factory ownership.

`measure_trial.mbtx` now accepts an optional fresh output path and reports
per-slot active, post-disconnect peak and last offsets. Raw ankle maxima may
contain spikes; reserved slot 23 is not a joint. The
[compact evidence](evidence/e1-supported-elbow-20261123.json) pins the raw
artifacts and preserves the incomplete result.

All named run directories are under
`/home/jiaanguo/lunakine-deployment-20261117/actor-elbows-20261121` on `.191`.
