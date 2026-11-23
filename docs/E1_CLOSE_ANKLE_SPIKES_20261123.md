# Closely spaced ankle spikes during a requested repeat

On 23 November 2026 the operator requested another instance of the larger
live-inference elbow gesture. `large-wave-powered-20261123-3` stopped after
2.4358 seconds and 1,165 motor frames. It did not complete the gesture or send
the planned return. All 27,960 transmitted motor records matched fresh valid
actor proposals, and the non-elbow position targets stayed fixed.

The transport reported `source telemetry expired`. The originating controller
fault was `ankle did not return to previous pose slot 9`. Its error unwound
through NPU cleanup before emitting the terminal stop, so the independent 40 ms
sender watchdog fired first. This report does not claim that error reporting
order has been fixed. The initial explanation based only on the sender receipt
was corrected after reading the complete controller/capture evidence.

There were no missing packet sequences near the stop. Maximum robot-source and
kernel-arrival gaps in the 300 ms window were 3.0943 and 3.1190 ms. The last
neural inference took 2 ms and used a 2 ms-old input. The last proposal was
emitted 42.2 ms before sender deletion, consistent with the watchdog expiring
after proposals ceased, rather than a network outage.

## State-machine cause

SDK ankle slots are ordered 9, 10, 20, 21 below; values are degrees.

| Packet | Left pitch | Left roll | Right pitch | Right roll |
| --- | ---: | ---: | ---: | ---: |
| 7588760, good | 1.503913 | 2.900499 | −1.910255 | 2.350783 |
| 7588761, spike | 3.245761 | −0.098355 | −3.158334 | −0.513630 |
| 7588762, recovery | 1.503913 | 2.900499 | −1.910255 | 2.350783 |
| 7588763, spike | 3.245761 | −0.098355 | −3.158334 | −0.513630 |
| 7588764 onward, recovery | 1.503913 | 2.900499 | −1.910255 | 2.350783 |

All 24 error fields were zero. Reported ankle velocities were around one
degree/second, inconsistent with these jumps in about three milliseconds.
Each anomalous sample recovered in the following packet. These observations
support isolated telemetry anomalies, not sustained physical ankle movement.
They do not identify or repair the upstream firmware/sensor cause.

After the first confirmed recovery, the detector reset its healthy history to
one. In the supported wider absolute envelope, abrupt-step detection required
two healthy samples. The second spike therefore bypassed provisional detection,
became `good`, and caused the real recovery to be classified as a new anomaly.
The fixed state machine keeps the retained good reference and confirmed recovery
as two validated samples for the explicit supported path. Abrupt supported steps
are detected even before sufficient initial history, then rejected rather than
silently admitted. Suspect packets still return `Wait`, never `Use`.

The default one-degree path retains its conservative rearming behavior. The
supported 5° baseline limit, 0.1° recovery bound, six-millisecond confirmation,
packet/health requirements, 40 ms freshness and motor parameters are unchanged.
Consecutive anomalous packets and sustained gradual leg drift still stop.
No zero adjustment or sensor-value substitution was added.

Local warning-denied tests passed 71 cases; `.191` passed 69 relevant native
cases and rebuilt both controller binaries. Regressions cover multiple isolated
spikes with one recovery between them, bad initial history, persistence, and
gradual drift beyond five degrees after recovery. Commit: `8cbe34cb`.

## Physical observation and verification

The interrupted trial's actual elbow changes were −5.3113° left / −4.6556°
right. Three seconds after disconnect both read back at their starting angles.
The interrupted trial's largest raw leg excursion was 2.9507°.
The operator confirmed **“平稳，手柄正常”** after this stop.

The failed run remains a failed completion test. Its strict completion audit
was not relaxed; the passing partial wire audit establishes frame consistency,
not successful execution of the whole gesture. Raw archives and timing/packet
reports remain on `.191` under the run directory. Read-only recorded-input
inference and the subsequent requested powered retry are recorded below.

## Exact recorded-input NPU prefix

`large-wave-close-spike-recorded-shadow-20261123-5` starts at the same first
fresh source packet, 7587574, as the original real controller. Only one constant
translation is applied to recorded host/source clocks; joint positions,
velocities, errors and IMU values are preserved. Initial source emission waits
for NPU preparation. Neither active freshness nor confirmation deadlines change.

The original recording contains two actual acquisition gaps: 1.9494 seconds
between 7586897 and 7587574, and 1.6983 seconds between 7588959 and 7589545.
Earlier attempts from the beginning correctly failed input freshness at the
first gap. A later starting window was also inappropriate because it started
the stationary-baseline check during recorded physical settling. These attempts
are not counted as successful model/control qualifications.

With the original first fresh packet, the corrected owner completed 149 real
Ascend inference updates, continued to input sequence 7588954, and never used
7588761 or 7588763 as model inputs. `audit_e1_ankle_prefix.mbtx` independently
matched every proposed input's 24 positions/velocities and healthy IDs to the
original capture, checked the single clock translation and continuous inference
sequence, and verified continuation beyond both glitches. Diagnostic passed.

It subsequently stopped at the recording's second genuine gap. The report
explicitly retains `completed_policy_trial:false` and
`command_writers_created:false`. This is a read-only regression of the failure
prefix, not a completed live-shadow or physical gesture. The strict completion
audit remains unchanged.

## Completed real retries and operator observation

After a fresh preflight, `large-wave-powered-20261123-4` completed its full
26.8967-second real gesture with 1,346 Ascend inferences, 700 policy updates
and 12,817 motor frames. All 307,608 transmitted motor records passed the
independent proposal/input/effort and fresh-wire audits. Measured elbow changes
were −64.5435° left and −53.5714° right. Three seconds after disconnect they
were at 0° and −0.0219° relative to takeover. Accepted leg displacement peaked
at 3.1036° with unchanged leg position references. Holding effort again reached
its existing 7.5 Nm cap.

The operator then asked whether this was physical execution and requested
another repeat. `large-wave-powered-20261123-5` reports full completion after
26.8998 seconds, 1,346 real inferences, 700 policy updates, 2,333 heartbeats and
12,805 motor frames. Both commanded elbow targets returned exactly and the
sender participant was deleted. Its complete independent capture audit is
retained with the final evidence record: all 307,320 motor records matched fresh
validated proposals. Measured elbow excursions were −64.5873° left / −53.2872°
right; both returned to their starting readings within three seconds of
disconnect. Accepted leg displacement peaked at 3.1474°, with all leg position
references fixed. This is measured settling, not physically motionless legs.

After that repeat the operator explicitly reported **“看到了，平稳，手柄正常”**.
This is an operator observation, kept separately from unchanged raw transport
receipts that do not themselves prove factory-controller ownership.

The [evidence manifest](evidence/e1-close-ankle-spikes-20261123.json) retains the
failed completion separately from both successful real retries, independent
audits, recorded-input diagnostic and SHA-256 hashes of raw archives on `.191`.

## Next session: shoulders, after charging

The operator requested adding shoulders on the next attempt, then stated that
the E1 was being shut down to charge. No shoulder actuation or subsequent
powered action is authorized by this record for the charging period.

The next-session scope is an explicit shoulder-and-elbow adapter for the same
trained actor, with fixed leg position targets. Verify all shoulder-axis SDK
IDs, directions, current raw pose and allowed ranges against the delivered E1
docs before extending the moving-joint whitelist. Commission bilateral shoulder
pitch first; add shoulder roll/yaw after their raw-range/zero questions are
resolved. The current actor configuration still authorizes only elbows 3/14.

Extend the owner, per-axis range/slew/following checks, raw-packet moving-joint
guard, independent transport validator and wire auditor together. Preserve
reserved slot 23 and every other fixed target. Show the constrained shoulder
targets on the website and run fresh live shadow before the next powered
hold/handback and small shoulder trial. Changing the learned model or adding a
generic whole-body passthrough is not necessary to expose existing shoulder
outputs, and is outside this commissioning step.
