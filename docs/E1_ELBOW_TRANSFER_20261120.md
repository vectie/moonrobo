# Elbow-only typing-pose transfer — 20 November 2026

Status: the native-coordinator powered elbow entry, hold and return completed
in `live-native-1`: all 6,101 samples, 58,043 motor-command frames, and sender
disconnection after 126.411 seconds. Independent wire, target and feedback audits
passed. The operator confirmed "Both elbows smooth; steady; handheld responds"
after completion. The standalone passive telemetry receiver and website remain
running; no command writer or automatic repeat remains active.

Earlier, after the operator confirmed
Walk mode, weight-bearing crane support and emergency-disable attendance, the
one-second powered current-pose hold completed: 479 motor-command frames, one
mode-2 request, no target changes, and sender disconnection. The operator then
reported "Steady; handheld responds". The powered elbow transfer subsequently
stopped after 35.512 seconds on `source telemetry expired`; it did not complete
entry, hold or the planned return. After that stop the operator reported
"Steady; handheld responds; movement looked smooth". No recovery trajectory or
automatic retry was sent.

The operator selected **elbows first, other arm joints later**. This is a
deterministic commissioning step using the typing reference's initial elbow
pose, not execution of the whole-body actor or the full typing gesture.

## Target path

`typing-elbows` captures a fresh 24-record hold after one second of healthy
telemetry. It changes only SDK pitch motors **3 and 14**. The target is
`-1.4477981791899937 rad` left (82.95° bend) and
`-0.5434064639344343 rad` right (31.13° bend), taken from frame zero of
`bones-230711__cellphone_typing_stand_one_hand_idle_R_001__A423_M`.

The path uses a 60-second minimum-jerk entry, two-second hold and 60-second
minimum-jerk return. The blend `10u³−15u⁴+6u⁵` has zero velocity and acceleration
at each endpoint. First and final commands preserve the exact captured elbow
positions. Feedback can pause reference advancement under the existing 5°
following criterion; fresh telemetry and the existing finite session deadline
remain required. The nominal path has 6,101 samples at 20 ms.

All **22 non-elbow command records** retain their positions, velocities,
feedforward torques and gains. Candidate gains remain those used by the
commissioned path: kp 50 on modeled motors, kd 1 on ankle slots and 5 elsewhere;
reserved slot 23 retains position 0, kp 0 and kd 5. No gain increase, new arm
motor, new firmware action, learned output or balance-controller change is
introduced. Fixed targets do not prove physically motionless legs.

## Checks completed

- Warning-denied native check passed; 15 elbow-control tests passed, including
  all transfer samples, exact return, rate/acceleration bounds, unchanged
  non-elbow fields and fault latching.
- Five independent Python transport tests passed. The new stage checks the
  analytic trajectory independently and rejects leg/shoulder edits, incorrect
  elbow targets and shadow messages on the live transport.
- The full new path passed in a network namespace containing **only loopback**:
  62,763 DDS motor frames / 1,506,312 motor records checked, one mode-2 request,
  exact target return and zero non-elbow command change. These were simulated
  fixture commands, not commands to the E1.
- Existing isolated hold, settling, gentle elbow, motor-error, input-stall and
  independent-watchdog cases passed after replacing fragile catch-based cleanup
  with error-deferred stop reporting. Fault reasons were preserved.
- Live E1 **shadow** completed all 6,101 reference samples, with 10,822 guarded
  target updates and 43,636 packets processed by the planner. Its active phase
  was 124.623 seconds with zero reference-wait ticks. All non-elbow fields and
  exact return were independently checked from the saved target stream.
- The complete shadow session captured 74,679 decoded records; planner,
  observer, decoder and sink exited successfully. No command writer was created.
  Elbow feedback was explicitly simulated for shadow tracking while other
  telemetry remained measured. The standalone read-only receiver was restored
  after packet observation; the website's live endpoint is fresh again.
- Nine website tests passed. The source menu now includes **双肘 · 平滑上机过渡**;
  `/e1-live.html?gesture=elbows&play=1` previews the same elbow targets with every
  other displayed joint held at the sampled baseline. Website playback remains
  read-only and does not start the powered stage.

The shadow's maximum raw leg-feedback excursion was 11.51°, despite no motor
commands. It is retained in the report without classifying it as proven motion
or proven sensor error. The existing suspended packet/leg-range treatment was
not changed. The earlier whole-body actor's large ankle outputs were not used.

## Partial powered transfer and timing investigation

The existing one-second current-pose hold completed with a fresh receive-only
preflight and the correct January transport. The operator confirmed steady pose
and responding handheld after disconnection.
The typing stage requires this fresh hold/handback receipt; a transport
disconnect alone is not accepted as physical handback evidence. The receipt
checker was corrected to consume the planner's actual
`max_fixed_target_change` field. A synthetic, network-free regression accepts
the current schema and rejects changed fixed targets or expired receipts.

Run `live-1` sent 17,112 motor-command frames and one mode-2 request before its
40 ms source-freshness check stopped it. Offline decoding of all **410,688 motor
records** verified action 11, zero axes, unchanged gains, and **zero change to
the 22 non-elbow targets**. This validates the partial command stream, not a
completed transfer or physical immobility of other joints.

The last commanded angles were approximately −52.647° left and −20.408° right;
the last active measured angles were −50.173° and −19.179°. Three seconds after
disconnect the measured angles were approximately −13.322° and −11.923°.
That subsequent motion was not the planned return and does not prove controller
ownership. Both command endpoints were deleted. The operator reported steady
pose, responding handheld and smooth observed elbow motion after the stop.

The capture recorded **zero kernel packet drops**. Within 100 ms of the stop,
maximum status-arrival spacing was 2.956 ms and robot source-clock spacing was
2.944 ms. Incoming status continued; the saved evidence points to a software
delivery/scheduling delay, without identifying a specific process yet. The
capture file is opened with `NoSync`, so a presumed per-packet fsync was ruled
out. The next shadow qualification uses a native coordinator and bounded timing
diagnostics. Its control deadlines, target validation and leg guard are unchanged.
The website was restored to the standalone receive-only subscriber after capture.

The first native-coordinator shadow (`shadow-native-1`) then passed: 6,101
reference samples, 10,819 guarded updates and 43,702 planner packets over
124.598 seconds, with no command writer. The independent target audit verified
all samples, exact elbow-target return and all 22 other records unchanged.
Maximum kernel-arrival-to-planner-feed age was **4 ms**, archival writes 3 ms
and planner pipe writes 1 ms. Its raw coordinator polling maximum included
startup and report serialization; subsequent polling diagnostics explicitly
cover the active phase. This run supports testing the native pipeline; it does
not establish the old delayed process or guarantee real-time scheduling.

A fresh native-coordinator powered hold (`hold-native-1`) completed next:
463 motor-command frames, one mode-2 request, no target changes and endpoints
closed. The operator again reported "Steady; handheld responds" after that hold.

The subsequent powered `live-native-1` completed all 6,101 samples and 11,020
guarded updates with zero reference-wait ticks. It published 58,043 command
frames and one mode-2 request, then deleted both command endpoints normally.
Planner active duration was 126.415 seconds; sender duration was 126.411 seconds.
All 22 non-elbow target records stayed fixed. The planner recorded raw maximum
leg-feedback change 13.481° and other non-elbow feedback change 0.896°; these raw
feedback maxima are preserved independently of the fixed-target result.

The final independent wire audit checked all **1,393,032 motor records** from
58,043 frames: action 11, zero axes, one mode-2 request, unchanged non-elbow
positions/gains/velocities/feedforward torques, and exact elbow-target return.
The target audit checked all 6,101 analytic samples and 11,020 guarded updates.
Measured peak angles were approximately **−79.723° left / −28.928° right**,
versus commanded −82.953° / −31.135°. At the last active packet, measured elbow
offsets from the captured start were −0.699° / −0.656°; three seconds after
disconnect they were −0.066° / 0°. These distinguish actual feedback from exact
commanded-target return. All 24 telemetry records remained available, including
reserved slot 23; no motor error was reported by the independent observer.

Maximum active coordinator polling gap and kernel-arrival-to-planner-feed age
were both **9 ms**; archival writes peaked at 7 ms and planner pipe writes at
4 ms. No deadline was relaxed. This powered run completed with the native
coordinator, but the earlier individual delayed process remains unproven.
The operator's completed-run observation is recorded separately from the raw
transport's `physical_handback_verified: false`; transport disposal alone still
does not establish physical handback.

The full shoulder/forearm gesture and whole-body learned control
remain separate later commissioning work. The software does not establish the
firmware's missing-command behavior or general physical handback semantics.

## Installed artifacts

Atlas source and runs are under
`/home/jiaanguo/lunakine-deployment-20261117/typing-transfer-20261120`.
The isolated transfer is
`moonrobo/deploy/e1/runs/typing-elbows-1795165146737`; live shadow is `shadow-1`.

The tested native commissioner SHA-256 is
`4838d4d3ef409bff597499b69e72a64723e4b903ecdc0454e89c8a1cb4d450a5`.
The tested January sender SHA-256 is
`2f04a83351b26736228e2a2df60137bc3340855299f66564ddbb058f4f31a07f`.
The completed powered run used the native coordinator SHA-256
`87be4a48ab95ea21299008983af026dae4e99af1296d9bcca9c62e00f44cfd31`.
The [machine-readable evidence](evidence/e1-elbow-transfer-20261120.json) records
raw artifact hashes and separates the earlier stopped run from the completed
native run. Operator observation is also stored beside the completed run as
`live-native-1/operator-observation.json` without modifying transport receipts.
Raw captures, model artifacts, credentials and unit telemetry remain outside Git.
