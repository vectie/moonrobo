# Right-knee investigation and constrained live shadow — 23 November 2026

The right-knee reading is a stable, motor-reported value, not a one-packet spike
or a value introduced by the MoonRobo decoder. The confirmed cause of the shadow
abort was an inappropriate admission rule: the read-only path applied the
guide's nominal mechanical range directly to unqualified raw feedback. Shadow
now retains the existing stationary/glitch assessment and reports nominal-range
discrepancies explicitly. The full constrained live-shadow run completed.

No motion/mode publisher, encoder-zero write, calibration adjustment, artificial
zero substitution, knee-angle clipping or expanded powered range was used.

## What the data establishes

An independent MoonBit reader parsed the previous fresh 225-second Ethernet
capture through pcap, IPv4/UDP, RTPS and the captured XCDR1 schema. It does not
use the SDK, C decoder or their floating-point conversion functions. Every
sample's motor IDs were checked, and the motor-19 IEEE754 double was read
directly from its serialized bytes.

| Evidence | Result |
| --- | --- |
| Unique status samples | 76,544 across 224,984 ms |
| Duplicate deliveries | 82,047; identical knee value for matching sequence |
| Distinct knee-position bit patterns | **1** |
| Serialized position bytes, little endian | `00000000008873bf` |
| Position | `-0.00476837158203125 rad`, or `-0.2732075668°` |
| Agreement with saved decoded telemetry | Bit-for-bit in all 76,544 samples |
| Fresh independent DDS preflight | Same reading; complete healthy 24-record status |

The SDK exposes `MotorState.pos` as a double, and our decoder copies that double
without a zero correction. The January development guide lists knee travel as
0°–135°; it supplies no measured zero/allowed raw-feedback interval for this
individual unit. Candidate calibration currently uses zero offsets of zero and
is explicitly unqualified.

These observations rule out the earlier one-packet glitch explanation and a
local decoding offset. They do **not** identify the physical encoder zero. A
small installation/encoder offset, actual deflection near straight, or another
upstream reporting condition cannot be distinguished by stationary telemetry
alone. No claim that the real knee is exactly at mechanical zero is made.

The completed new shadow capture was audited independently again: all 76,640
unique samples over 224,977 ms contain the same knee-position bit pattern and
match the live decoder exactly. The unchanged reading remains in the successful
run rather than being replaced with zero.

## Software correction and retained checks

The shadow owner now calls `Detector::begin_hold()` on the already validated
stationary history. This preserves the current raw pose, continuity, healthy
streak and isolated-ankle confirmation behavior instead of switching to an
absolute SDK-range gate. Nominal-range discrepancies remain visible in every
proposal and in the final report; motor 19 is still listed. Previous applied
actions use the unchanged raw held targets, including this knee reading.

The change is restricted to `--shadow`, whose only command sink is a file.
Powered admission still calls the strict initial SDK-range validator and still
rejects this knee reading before producing a proposal. The transport continues
to reject shadow-marked frames. Physical calibration and powered qualification
remain separate work.

Four warning-denied native tests pass. They check that the exact measured knee
value survives shadow admission, that powered admission still rejects it, that
the existing relative limit stops gradual knee drift, and that an isolated ankle
spike must recover while a sustained excursion stops. Existing thresholds are
unchanged: the shadow stationary bound is 1°, ankle recovery is within 0.1° and
6 ms, and input/inference freshness remains 40 ms. No missing sample is filled
and no sensor value is rewritten.

## Completed real-inference constrained shadow

The installed owner ran on actual incoming E1 status and IMU through LunaKine
Ascend FP32, with the unchanged 25% elbow adapter and typing reference. It
completed the initial hold, ten-second model-driven approach, 13.52-second
reference and explicit return. This is the constrained owner, unlike the separate
stationary inference diagnostic in the [earlier record](E1_ACTOR_LIVE_SHADOW_20261123.md).

| Measurement | Result |
| --- | --- |
| Active duration | 31,704 ms |
| Neural updates / policy-phase updates | 1,586 / 1,177 |
| Target heartbeats / consumed status packets | 2,735 / 11,386 |
| Maximum inference / scheduling lateness | 3 ms / 5 ms |
| Maximum kernel-arrival-to-inference age | 4 ms |
| SDK command records / unchanged records | 24 / 22 |
| Moving candidate slots | 3 and 14 only |
| Position-bounded policy updates | 0 left, 0 right |
| Slew-limited policy updates | 229 left, 238 right |
| Return | Both elbow candidate targets exactly equal initial hold |
| Nominal SDK range discrepancy at hold | Motor 19, retained in reports |

The independent target auditor passes for every saved proposal, including raw
action mapping, applied-action feedback, filters, clocks, all fixed records and
exact return. The [evidence manifest](evidence/e1-knee-shadow-fix-20261123.json)
separates this numerical/file-sink result from physical actuation. Raw artifacts
are retained in `output/e1-knee-shadow-fix-20261123` locally and
`/home/jiaanguo/lunakine-deployment-20261117/actor-elbows-20261121/knee-fixed-live-shadow-20261123-1`
on Atlas. The raw-byte audit is reproducible with
`scripts/audit_e1_knee_capture.mbtx PCAP DECODED_STATUS WRITER_GUID NEW_REPORT`.

The passive session, decoder and observer all exited successfully. The observer
received 73,736 status samples and discovered no command owner; a final
receive-only discovery check passed with another 680 samples and no command
publisher. The actor has exited. No motion or mode commands were sent.
