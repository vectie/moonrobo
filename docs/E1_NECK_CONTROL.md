# E1 neck control and the stale target incident

The external E1 neck is now controlled by the MoonBit package
`src/neck_control` and the `cmd/neck_control` executable. The old XLeRobot
Python startup path and the one-off SSH test scripts are not the control path
for this assembly. A thin C layer supplies Linux serial I/O, exclusive port
ownership, clocks, signal handling and durable file operations. Protocol
encoding, command admission, arming, movement and shutdown policy are MoonBit.
The one-off movement, recovery and disable helpers were archived as
non-executable text and replaced with failing entry points, so old script
paths cannot silently bypass the new controller.

The specific failure that occurred on 2026-11-25 is forbidden by the new API
and regression tests. This is a bounded software guarantee, not a claim that
hardware can never move unexpectedly. Power loss, physical slip, firmware
behavior and releasing a loaded joint remain physical failure modes.

## What happened

Both STS3215 motors completed small left, up, right and down movements. The
one-off script then disabled motor 7 torque and restored a saved nine-byte
SRAM block beginning at register 41. That block contained live motion
commands, not merely configuration:

| Register | During the slow test | Restored during faulty cleanup |
| --- | --- | --- |
| Acceleration 41 | 5 | 0 |
| Goal position 42 | Near the saved starting pose 1927 | 0 |
| Goal time 44 | 0 | 0 |
| Goal speed 46 | 35 ticks per second | 0 |
| Torque limit 48 | 300 of 1000 | 1000 of 1000 |

In position mode, speed zero means maximum speed, not a stop command. Raw
position zero is not this neck's neutral pose. Independently measured STS3215
behavior also shows that writing a goal position can re-energize a servo after
torque has been disabled. Therefore a torque-off command is not a safe barrier
against a subsequent position write.

Motor 7 subsequently reported position 1544 and load magnitude 619; after both
motors were disabled it was at position 1193. The unsafe cleanup write and the
motion are recorded facts. Re-energizing on a position write strongly explains
the event, but the exact transient internal torque state on these units was
not isolated by reproducing the hazardous command on the assembled neck.
Releasing holding torque can also permit gravity or cable-driven motion.

After the operator confirmed the bracket and cables were free, each axis was
returned slowly to its saved encoder pose. Readback was motor 7 at 1925 with a
goal of 1927 and motor 8 at 2056 with a goal of 2047. Both held with speed 20,
acceleration 3 and torque limit 300. Both units report model 777 and firmware
3.10. A returned encoder pose does not independently prove the mount did not
slip; inspect mechanical alignment after an incident.

The old XLeRobot code also enables torque without first latching the measured
pose, defaults `max_relative_target` to `None`, and calls
`bus2.configure_motors()` twice while omitting bus 1. These are audit findings,
not proof that every earlier unexpected movement had the same cause. The
optional displacement-limit branch also mixes action names ending in `.pos`
with unsuffixed feedback keys; simply enabling that setting is insufficient.

## Hardware identity and commissioned envelope

| Item | Verified value |
| --- | --- |
| ELF host | `elf@192.168.2.192` |
| USB adapter | QinHeng `1a86:55d3`, serial `5AB0182917` |
| Stable Linux port | `/dev/serial/by-id/usb-1a86_USB_Single_Serial_5AB0182917-if00` |
| UART format | 1000000 baud, 8N1, no flow control |
| Pan | ID 7; positive encoder motion looks right |
| Tilt | ID 8; positive encoder motion looks down |
| Saved center | Pan 1927; tilt 2047 |
| Software bounds | Pan 1870–1984; tilt 1990–2104 |
| Hardware EEPROM limits | Pan 933–3043; tilt 1040–3204 |
| Raw homing-offset fingerprint | Pan 3948; tilt 1882 |

The software bounds are a conservative approximately five-degree commissioning
envelope around the saved center, not the full mechanical limits. A jog is
relative to the freshly measured pose and is denied if its destination would
leave that absolute envelope. Repeated jogs cannot move the envelope. There
is no automatic re-zero, clipping, wraparound or expanded recovery range.
Changing the assembly, calibration or usable range requires a reviewed
profile change and new clearance checks.

## Mandatory control rules

1. **One owner.** The stable adapter is opened with `flock` and `TIOCEXCL`.
   Stop legacy controller processes first. Exclusive mode prevents later
   ordinary opens; it cannot revoke a descriptor already open elsewhere or
   prevent a privileged process or a second physical bus master.
2. **Every goal is actuation.** Treat a goal write as potentially enabling
   torque. The only transport writes are the exact bounded speed, torque and
   acceleration values, a measured-position latch, a one-tick step, explicit
   torque enable and explicit torque release. Bulk restoration, arbitrary
   registers, EEPROM writes and a raw zero target are unavailable.
3. **Prepare before position.** Read and validate identity, calibration and
   both current poses. Configure torque limit 300, speed 20 and acceleration
   3. Read back each stage. Only then latch the measured current position;
   verify the latch before explicit enable. An already energized motor with
   a distant old target is rejected, not automatically corrected.
4. **Bound every step.** A new goal differs by at most one encoder tick from
   the preceding goal, at intervals of at least 50 ms. Absolute bounds remain
   anchored to the commissioned center. Current profile, mode, torque, goal,
   tracking error and electrical/thermal feedback are checked throughout.
5. **Fresh means fresh at dispatch.** Feedback is timestamped before its
   request and may be at most 150 ms old. Audit records are persisted before
   transmission; freshness is checked again after persistence and at the
   native write boundary. Delayed I/O cannot silently send an old command.
6. **No silent retry or resume.** A timeout, bad checksum, wrong reply ID,
   servo alarm, changed target/profile, power-reset settings, torque loss,
   interrupt or tracking failure stops the command. An acknowledgement lost
   after an applied write does not cause a retry or replay.
7. **Finish by holding.** Successful completion leaves the last verified
   target and bounded profile in place. Closing the port does not change
   torque or restore saved bytes. A fault stops goal generation and preserves
   the last bounded target; there are no actuator cleanup writes.
8. **Release is explicit and terminal.** `Release` sends only torque-off
   writes to IDs 7 and 8, followed by readback. There can be no later position
   or profile write in that operation. Support the camera before releasing
   torque: a limp joint can physically move even with no position command.
9. **Crashes and replay are latched.** Before actuation, create and persist
   `/home/elf/moonrobo-neck/inflight-or-fault`. Consume the exact intent ID in
   a separate exclusive-create journal. Only a fully successful holding
   operation clears the marker. Faults, crashes and explicit release leave
   it present. Changing audit paths does not bypass it. Intent IDs cannot be
   replayed after restart.
10. **Use the existing MoonRobo gate.** Physical requests require a fresh,
    exact-action, ready-for-execution safety receipt for robot
    `noetix-e1-neck`, bridge `elf2-neck-usb` and capability
    `control.low.neck`. The profile requires dry-run evidence, operator
    approval and the developer gate. The CLI does not mint execution grants.

Receipt files are trusted local MoonRobo artifacts, not cryptographically
authenticated remote credentials. Do not expose this CLI or writable receipt
directories to untrusted clients. The motion API has no remote web endpoint.

## Commands

Build from the repository root:

```sh
moon test --target native src/neck_control
moon build --target native --release cmd/neck_control
```

The default command is read-only. On ELF:

```sh
/home/elf/moonrobo-neck/neck-control status
```

Simulation and planning never open the serial device and are explicitly
labelled simulated. They exercise the same command state machine, including
a simulated servo that re-energizes on a position write:

```sh
moon run cmd/neck_control --target native -- simulate left 2
moon run cmd/neck_control --target native -- plan center
```

The plan contains the robot profile, exact command intent and simulation
trace. Submit that intent through the existing MoonRobo evaluation, dry-run
and approval workflow. A plan file alone cannot authorize execution. Once
that workflow has produced the matching fresh ready receipt:

```sh
/home/elf/moonrobo-neck/neck-control execute APPROVED_READY_RECEIPT.json /home/elf/moonrobo-neck/neck-audit.jsonl
```

The receipt expires after 60 seconds, must match the exact action, and its
intent ID is consumed before sending actuator commands. `Release` also
requires an explicit matching request and leaves a review marker.

Deployment is a MoonBit script:

```sh
moon run scripts/deploy_neck_control.mbtx
```

It builds MoonBit-generated C with the matching runtime on ELF, runs an
explicit simulation and read-only status, and installs the native binary.
It sends no movement request. The script currently uses this commissioning
session's SSH control socket by default; pass a different control socket as
the script's first argument for a future session. It contains no passwords.

## Diagnose a future incident

Preserve the JSONL audit log and the in-flight/fault marker before restarting
or changing calibration. Every transaction records a sequence number,
wall-clock and monotonic timestamps, motor ID, decoded register parameters,
exact transmitted packet, received packet and feedback. An authorization
record ties each write to its immediately preceding feedback.

Check the last `tx-before-send` record first. A changed goal means a software
command reached the transmission boundary; a position change with no new
goal requires checking torque release, a power/reset event, external writers,
mount slip or mechanical forces. A low final voltage sample cannot exclude
brief supply transients: capture the supply electrically when investigating
brownouts. A returned ACK confirms a protocol reply, not physical clearance.

Do not delete the marker to retry blindly. Inspect the bracket, cable path,
calibration fingerprint, last target and power first. After explicit operator
review, archive the marker rather than erasing the evidence, obtain a new
intent/receipt, and start with a read-only observation. Keep consumed-intent
journal files; they prevent replay. There is no automatic acknowledgement or
automatic large-angle recovery command.

The CLI actively monitors only while a command is running. After it exits,
the servo holds its last bounded target using its own firmware. This is not a
continuous hardware watchdog or a safety-rated emergency stop. Software
cannot guarantee zero physical movement after power loss or torque release.
Use a supported/balanced mount, suitable mechanical stops and a reachable
power disconnect for physical testing.

## Regression evidence and sources

The [2026-11-25 qualification record](evidence/e1-neck-control-20261125.json)
records 16 neck regressions plus the camera transport test passing, Linux
pseudo-terminal AddressSanitizer qualification and native ELF read-only
verification. The physical status audit contained 12 READ packets and zero
WRITE packets. The rewrite did not run another physical movement test.
The live viewer and camera capture were closed at the operator's request.

Tests cover the exact release-then-zero-target incident, startup with a stale
zero goal, position-write re-energizing, startup ordering, all four directions,
absolute and relative bounds, timing, stale feedback, changed profile/torque,
lost acknowledgements, failed/slow audit persistence, malformed replies,
terminal release, raw-write whitelisting, durable crash markers, one-use
intent journals and exact-action safety receipts. They do not establish that
the entire physical neck workspace is collision-free.

`tests/neck_serial_transport.c` additionally exercises the native Linux
transport against a pseudo-terminal under AddressSanitizer: exclusive
ownership, fragmented and partial replies, expired-dispatch zero-byte
transmission, invalid buffer bounds and closing/reopening. This test never
opens a physical device and does not modify the installed MoonBit allocator.
Deployment retains its result and the installed binary hash under
`_build/neck-control-elf/` alongside the read-only ELF status capture.

- [Firsthand STS3215 position-write and torque measurements](https://github.com/iory/feetech-cli#torque)
- [Register reference measured on firmware 3.10](https://github.com/commanderfun/STS3215/blob/main/REGISTER_REFERENCE.md)
- [MoonRobo safety model](SAFETY.md)
- Local incident evidence: `/Users/kq/moonsuite/inputs/elf2-neck-control-20261125/MOTION_INCIDENT.json`
- Camera viewer: `http://127.0.0.1:4195/`; the camera cannot see its own neck clearance.
