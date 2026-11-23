# E1 live actor shadow — 23 November 2026

Follow-up: the [right-knee investigation](E1_KNEE_SHADOW_FIX_20261123.md) verifies
the stable on-wire value and corrects the read-only shadow admission rule.
The complete constrained live-shadow path subsequently passes with raw values
retained and nominal-range discrepancies reported. Powered admission remains
unchanged. This record preserves the earlier attempts and separate diagnostic.

`eno1` on Atlas `.191` is connected: carrier `1`, state `UP`, address
`192.168.55.101/24`, persistent connection `E1 robot (eno1)`. The 310P3 reports
healthy. Receive-only discovery identified E1 status writer
`01106fe078686eef6220217e00000203`, all 24 records and the expected January
motor/mode reader types. No motor or mode publisher was created for this work.

Two different results must be kept separate:

| Path | Result |
| --- | --- |
| Installed constrained elbow controller, real status, file sink | Stopped at right-knee feedback range check; full policy trial incomplete |
| Existing receive-only live inference diagnostic | Completed 15 seconds, 750 Ascend FP32 updates at 50 Hz |

## Decoder correction and constrained trial

The first constrained attempt stopped before a baseline with `packet continuity
lost`. The passive capture contained repeated RTPS DATA from the same status
writer: equal sequence, source timestamp and raw serialized payload, delivered
to different local readers. The byte decoder had forwarded both copies.

The corrected decoder emits the first receipt once and suppresses only identical
duplicates. It compares raw bytes and source timestamps in a bounded identity
cache. Conflicting duplicates and unknown old samples fail; missing unique
sequences remain visible to the existing continuity guard. Source/receipt clocks,
joint values and all guard thresholds are unchanged. Five new network-free
regression tests pass; the existing admission/transport tests also pass
(16 tests total). Duplicate handling changes no native guard thresholds.

The second attempt established the current-pose baseline and performed one
Ascend update. Its single unsent target was the unchanged baseline, with zero
model authority. The next packet stopped the owner with
`leg feedback outside SDK joint range slot 19`. SDK motor 19 is the right knee;
its reading is `-0.00476837158203125 rad` (`-0.2732075668°`), below the configured
January guide's `0°` lower bound. The later diagnostic records this same reading
in all 750 frames. This is a stable reading-versus-range discrepancy, not evidence
of a new knee jump or proof of its physical cause. No zero adjustment, clipping,
range expansion or physical command was attempted.

This also exposed an admission-order bug: the first result of the suspended
guard had been ignored when establishing the hold, so the invalid current-pose
baseline could reach the proposal sink once. The owner now requires that guard
to accept the captured pose before generating any proposal. A new warning-denied
native test uses the exact knee reading and checks rejection at admission. The
installed corrected executable was also exercised on a declared ten-second
window of this live capture: it rejects motor 19 with **zero target proposals**.
That regression is offline replay, not an additional live or powered trial.
An initial replay-harness attempt timed out draining startup input; its archive
is retained. The final bounded fixture preserves all 3,455 records from capture
offsets 15–25 seconds and rebases only clocks; no deadline or threshold changed.

The second passive capture decoded 76,544 unique samples and suppressed 82,047
exact copies. The independent receive-only observer passed with 73,899 samples
and no allowed/observed command owner. The session receipt has
`command_writers_created:false`, `planner_status:1`, and successful observer,
decoder and file-sink exits. Its startup archival-latency counters include NPU
loading and are not described as successful active-control timing.

## Completed inference-only diagnostic

The existing `e1_live_actor_shadow-qualified.exe` used the reviewed
`libe1_readonly_status.so`: it creates only a status reader and rejects
publication. This separate run used the frozen 23-joint actor and a stationary
current-pose diagnostic reference. It did not run the typing reference or the
constrained elbow adapter.

- Backend: LunaKine Ascend FP32; duration 15,000 ms; 750 updates; no missed periods.
- Maximum scheduling lateness: 1 ms; inference: 3 ms; callback-to-output age: 5 ms.
- All 750 recorded frames have SDK IDs 0–23, 23 measured/model joint values,
  29 raw action channels, six zero inactive channels and `published:false`.
- Nominal elbow outputs ranged from approximately `-0.27415` to `-0.20680 rad`
  left, and `-0.17989` to `-0.13041 rad` right. These are unexecuted diagnostic
  neural targets, not filtered elbow-controller commands or measured movement.
- Raw whole-body outputs still violate the selected simulation model's left
  ankle pitch/roll travel in all 750 frames. The existing calibration remains
  diagnostic and this run does not qualify whole-body actuation.

The [evidence manifest](evidence/e1-live-actor-shadow-20261123.json) pins the raw
reports and trace hashes. Private artifacts are retained under
`output/e1-actor-live-shadow-20261123` locally and
`/home/jiaanguo/lunakine-deployment-20261117/actor-elbows-20261121` on Atlas.
The earlier [deployment plan](E1_ACTOR_CONTROL_20261121.md) remains the intended
sequence. Fresh-telemetry numerical inference now passes, while the complete
constrained shadow trial remains blocked by the right-knee reading/range
discrepancy. This request remained shadow-only.
