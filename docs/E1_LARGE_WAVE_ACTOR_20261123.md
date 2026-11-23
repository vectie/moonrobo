# Larger reference-conditioned neural elbows, 23 November 2026

The operator found the first live-inference gesture too small and requested a
larger upper-body action. The trial retains the explicit elbows-only scope:
motor IDs 3 and 14 may change position; all other 22 position records are fixed.
The operator confirmed normal handheld response, Walk mode, crane support and
emergency-disable attendance before this larger trial.

## Reference and configuration

The frozen actor remains
`031c4f35c09b86233d4ae05a44fdf5b6942a327224b112f7bc043b53c59727c0`.
The new reference is `bones-240327__wave_two_hands_R_001__A533_M`, 200 frames
at 20 ms, exported using training's existing reference/goal encoder. This is a
validation-split reference, not a claim that this exact gesture was in training.
It supplies goals to real live Ascend inference; no joint trajectory is replayed
as a robot command. The shoulders remain fixed, so this is the elbow component
of the conditioned action rather than a complete two-hand wave.

The previous small trial clipped elbow targets to [−6°, 0°] and used 25% actor
authority. `prepare_large_actor.mbtx` prepares a separate config with [−90°, 0°]
absolute elbow bounds, full neural elbow authority, and 5.890486°/s slew on each
elbow. The 500 ms response and 2 s engagement filters remain. The speed equals
the peak of the previously completed supported 90°/60° elbow strokes. A 90°
bound is not a forced target. The 5° following/stationary feedback envelope and
position-only bounded leg holding remain unchanged.

Artifact identities:

| Artifact | SHA-256 |
| --- | --- |
| Original 75-clip dataset | `346d00c65383dc9bb08627307cca7f76f9b627c5bc769838bd5b977c257ecaf5` |
| Source motion | `401aab96c7060139a6da042001398f1977f1982843c19c653f2593f24cea427f` |
| Prepared wave reference | `86de9f7d8215f07e46373b8d6f0495cdec254a9bb4077d5ad2de6653951b734c` |
| Larger actor config | `4fc7435a272d0d266ae9b384a327c66fb8c16032101713379fa1969d93ab4566` |
| Supported holding profile | `739579e0d822a954cce3fa5713dcd8bf0ad10964b4fd299e1f504ba1ddd1afb9` |

## Shadow and independent checks

`large-wave-shadow-20261123-1` completed 1,177 real Ascend inferences, 700 policy
updates and 2,032 heartbeats over 23.525 seconds. Maximum inference, original
input age and lateness were 3, 4 and 5 ms. All processes completed successfully;
capture timeout 124 was expected. No motor/mode writers were created. Every
proposed target and holding-integral input passed the independent raw-status
audit, with all 24 IDs checked and exact final elbow-target return.

The left/right shadow targets reached absolute bends of 48.9303° / 38.9681°,
or changes of 47.8047° / 37.9081° from takeover. Neither position bound clipped
any policy tick. Eight exact captured input histories/goals were independently
run through ONNX Runtime CPU FP32: maximum error across 232 outputs was
`3.337860107421875e-6`, below the unchanged `1e-4` threshold.

The first isolated replay stopped at 5° because its saved, unexecuted shadow
elbow feedback was being evaluated as physical following. The corrected sender
omits that physical assertion only in its existing loopback-only network
namespace mode. It still validates actual model/adapter mathematics, clocks,
fixed positions and holding effort. Live admission explicitly reconstructs the
default strict following validator; the 5° powered bound is unchanged. Regression
tests show the same large unsent sample fails powered following and that invalid
leg effort still fails isolated replay.

`large-wave-isolated-20261123-2` passed 11,214 DDS motor frames / 269,136 records,
exact elbow return and endpoint disconnection. Its stale-model scenario rejected
expired original input despite fresh transport telemetry. This is a transport
replay, not fresh inference or physical tracking evidence. All 43 Python tests
on `.191` passed, alongside warning-denied script checks and four website tests.

The website at `/e1-live.html?gesture=policy` serves the larger shadow candidate
on the right and fresh measured telemetry on the left. Its unpublished candidate
labels remain: this preview tape is not a claim that the physical run exactly
reproduced shadow targets. The policy and fresh-pose endpoints returned HTTP 200.
The existing read-only mirror receiver in the older `typing-transfer-20261120`
deployment was retained. An attempted additional subscriber exited on a shared
temporary-file collision; no duplicate subscriber was left running. The web
relay uses prebuilt native follow/relay binaries so compiler diagnostics cannot
enter its JSON stream. Stop the existing read-only receiver before a subsequent
commissioning capture so that it has only one status subscription. The capture
decoder's existing byte-exact retransmission deduplication was active; both real
trials passed complete input/continuity audits. No automatic control service was
installed by this work.

## Real trials

Archives are under
`/home/jiaanguo/lunakine-deployment-20261117/actor-elbows-20261121` on `.191`.
The first run, `large-wave-powered-20261123-1`, completed successfully after
26.940 seconds, 1,348 real inferences, 700 policy updates and 12,827 DDS motor
frames. Its independent raw-input/holding/target audit passed. All 307,848 wire
motor records matched identical fresh actor proposals, with exact elbow-target
return, mode 2 once / action 11 / zero axes, and participant deletion.

| First real trial | Left elbow | Right elbow |
| --- | ---: | ---: |
| Commanded change from takeover | −67.7608° | −56.6508° |
| Measured change | −65.0025° | −54.1178° |
| Measured residual at disconnect | −1.2677° | −1.8142° |
| Measured residual three seconds later | 0° | −0.4808° |

The maximum accepted leg displacement was 2.9288°, with leg position references
unchanged. Raw maxima include brief ankle spikes; their largest leg excursion
in the complete stream was 3.1320°. Leg integral effort reached its 7.5 Nm cap,
so this does not solve precision holding or establish preload continuity.

Live inference differed from stationary shadow. The larger observed fold is
not a substituted preset: the model consumes the changing physical observation
and previous applied action. During the first real trial, nominal neural elbow
targets briefly passed −90°; the adapter clipped 18 left and 8 right policy
updates while retaining the same filter, slew and physical-following checks.
The actual sent targets stayed within the explicit bounds.

The operator requested a repeat. `large-wave-powered-20261123-2` then completed
with the same configuration: 26.917 seconds, 1,347 real inferences, 700 policy
updates, 2,334 heartbeats and 12,817 DDS motor frames. No second reader/controller
was started until the first capture ended and its audits passed. Both targets
returned exactly and the participant was deleted. The repeat's independent
proposal/raw-input and wire audits passed all 307,608 motor records. Measured
left/right changes were −64.5873° / −53.6588°, versus commanded changes of
−67.5116° / −56.1511°. Residuals at disconnect were −1.2677° / −1.4207°, and
three seconds later 0° / −0.0219°. Maximum accepted leg displacement was 2.9507°;
all non-elbow position references remained fixed. The same 7.5 Nm holding cap
was reached. Seventeen left and eight right policy ticks were position-clipped.

Both real runs completed without a fault and retained the original 5° following
and stationary guard. The [evidence manifest](evidence/e1-large-wave-actor-20261123.json)
contains the exact receipts, measurements, independent audits and archive hashes.

Endpoint deletion does not establish physical factory handback. Supported
holding does not qualify balance, walking, shoulder actuation or whole-body
policy deployment. The final operator observation after the repeat is pending.

Subsequent requested repetitions exposed a closely spaced ankle-spike state
bug, which was fixed without changing the protection thresholds. Two further
real elbow gestures completed and the operator confirmed seeing stable motion
and normal handheld response. See the [failure, fix and further trials](E1_CLOSE_ANKLE_SPIKES_20261123.md).
The operator then said they were shutting down for charging and requested shoulders for the next
session; current powered authorization remains elbow-only.
