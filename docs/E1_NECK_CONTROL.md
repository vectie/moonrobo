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
| Goal speed 46 | 35 (raw setting) | 0 |
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
| Pan | ID 7; initial camera-based observation labeled positive motion “right”; scene versus shaft direction remains unresolved |
| Tilt | ID 8; initial camera-based observation labeled positive motion “down”; scene versus shaft direction remains unresolved |
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
   both current poses. For profile v2, verify factory speed parameters and
   configure torque limit 300, speed 50 and acceleration
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

The CLI actively monitors only while a command or joystick session is running. After it exits,
the servo holds its last bounded target using its own firmware. This is not a
continuous hardware watchdog or a safety-rated emergency stop. Software
cannot guarantee zero physical movement after power loss or torque release.
Use a supported/balanced mount, suitable mechanical stops and a reachable
power disconnect for physical testing.

## Left Joy-Con neck control

The paired left Joy-Con is `98:B6:E9:20:21:41` (Bluetooth, Nintendo
`057e:2006`). The right Joy-Con is ignored. The neck input path never launches
the old XLeRobot arm/wheel controller. In particular, that old example's
startup `move_to_zero_position` is not used. Its joystick was assigned to
arm translation and its left directional buttons to the head; the new path
assigns the **left analog stick directly to neck pan and tilt**.

| Input | Behavior |
| --- | --- |
| Center stick, release ZL | Make input eligible to arm |
| Hold ZL while centered | Arm; first arming prepares and latches both measured poses |
| Move stick while holding ZL | X right = pan right; Y down = tilt down |
| Center stick or release ZL | Stop generating steps; hold the last target |
| Minus | End the session, with no return-to-center or torque release |
| Disconnect, stale input, stalled loop or servo fault | End and latch the fault; no automatic resume |

The stick has a 20% center deadzone. Outside it, requested target slew scales
from 1 to 20 encoder ticks/second (about 1.76 degrees/second at full input).
This bounds target changes, not instantaneous physical motor velocity. Each axis
still advances at most one tick per 50 ms. Diagonal input is supported, with
both axes checked. Outward velocity stops at the existing fixed bounds:
pan 1870–1984, tilt 1990–2104. It cannot shift the envelope. There is no gyro
control, automatic centering, full-angle mode or queued destination.

Startup with ZL held or the stick deflected cannot arm. After releasing ZL
with the stick deflected, center it with ZL released before pressing ZL again.
Every session lasts at most 300 seconds and requires an exact
`Joystick(seconds)` execution receipt through the same MoonRobo gate. A
previous Jog or Hold receipt cannot authorize joystick control. The receipt
must be fresh when opening the session; the explicitly approved duration
bounds subsequent input. One-use intent journals and the persistent crash
marker cover the whole session, including idle time. Reconnecting a Joy-Con
does not restart a session or clear a marker.

The Linux input layer reads calibrated ABS_X/ABS_Y and ZL/Minus from the
physical evdev device, verified by its vendor/product and Bluetooth MAC,
excluding the separate IMU node. It also requires a newly received periodic
full HID report, discarding any pre-existing backlog first. A connected flag
or unchanged evdev state is not proof of a live controller. The evdev
descriptor is read-only. Like the installed XLeRobot Joy-Con library, input
startup enables sensors and requests full `0x30` reports; it also selects one
steady player LED. Those three HID setup packets are constructed in MoonBit
and whitelisted again in C. Rumble changes, SPI writes and arbitrary HID
outputs are forbidden. The input monitor never opens the robot servo port.
Sensor and report-mode setup require a matching positive HID acknowledgement;
a successful host write alone is insufficient. A controller that cannot
acknowledge setup cannot be admitted as live input.
Setup outputs are separated by at least 50 ms, enforced in both MoonBit and
the native whitelist. The native input reader waits at most 125 ms for a
new full report, with the sample timestamp taken before waiting.
Fresh input and motor feedback each have a 150 ms maximum age. Input age
and feedback age bound dispatch even after audit persistence. The native
serial boundary checks ZL, Minus and device presence again immediately
before sending a guarded write. If release races a pending write, the
operation may terminate with a fault instead of continuing the session;
there is no retry, cleanup target or automatic re-arm.

Releasing ZL stops **new** goals, not physical motion instantaneously. The
servo may finish tracking its last small target. This is not a hardware
emergency stop, and it deliberately keeps holding torque rather than
dropping the camera.

Read-only input check (never opens the servo adapter):

```sh
/home/elf/moonrobo-neck/neck-control joystick-monitor 30
```

Motion-free simulation and exact session planning:

```sh
moon run cmd/neck_control --target native -- simulate joystick 120
moon run cmd/neck_control --target native -- plan joystick 120
```

Simulation demonstrates left/up/right/down input and trigger release using
the same MoonBit loop. `armed_input` in the monitor refers only to input
admission, not energized motors. Submit the plan through the existing
evaluation/dry-run/approval workflow, then use `execute RECEIPT AUDIT` as
above. There is no unrestricted joystick command that bypasses the receipt.
The monitor can wait for a sleeping or disconnected controller and reopen
its input descriptors. Every such reopen resets its input arming state.
This behavior is confined to the monitor: physical execution never reconnects
or retries. The first live sample includes the kernel axis values and ranges
for calibration diagnosis, and subsequent samples include a periodic
heartbeat even if the stick is unchanged.

ELF setup: Bluetooth must be powered on and unblocked. The commissioned
controllers are already paired/trusted. Wake the left one with L. If needed,
hold the small SYNC button on the rail until its LEDs flash, then reconnect
to the saved device. The original `joycond` service uses **L + ZL together**
to select the left Joy-Con as a single controller, distinct from Bluetooth
pairing; see its [usage instructions](https://github.com/DanielOgorchock/joycond#usage).
However, the installed daemon masks the physical evdev device's ACL while
waiting for selection, preventing the ELF user from opening it. Stop that
daemon for the direct neck path, reload/trigger the scoped input rule below,
and check the effective ACL before starting a monitor. The neck reader
initializes its own report mode and LED and uses the physical controller's
identity rather than a combined virtual pad. Do not launch the legacy robot
controller alongside it.
The original daemon was disabled for this direct neck input setup so it
cannot mask the physical input ACL again at the next boot. Re-enable it
explicitly if returning to its combined gamepad workflow.

Install `config/99-zz-moonrobo-neck-joycon.rules` in `/etc/udev/rules.d/`,
reload rules and trigger the left Joy-Con input device. This gives group
`elf` access only to that controller, rather than adding the user to a group
that can read every keyboard. Existing system HID permissions must also
allow the ELF user to open that controller's hidraw node for input setup.
If `getfacl` shows the ELF user's entry as `effective:---`, a `joycond` mask
still blocks access even if the group is correct. A scoped
`setfacl -m u:elf:r /dev/input/eventN` can restore input access after stopping
the daemon; identify eventN by the controller's MAC, never a stale node number.
Device numbers
such as `event8` and `hidraw1` are not assumed by the controller.

During commissioning on 2026-11-25, BlueZ twice reported a connected
controller while no HID reports arrived; the kernel also logged LED request
timeouts and dropped IMU reports. A manual SYNC/reconnect restored reports.
USB runtime autosuspend was checked and the Bluetooth adapter was already
set to `on`/`active`; it was not changed as a speculative fix. Adapter power
was cycled to clear a stale connection. The original `joycond` service was
restored to test its documented L + ZL single-controller selection. Comparing
`/home/elf/lerobot/examples/joycon_test_read_CN.py` confirmed that the installed
input library explicitly enables sensors and full HID reports, which the
first neck reader omitted. It also exposed the daemon's masked input ACL.
Both input setup gaps were corrected. The unchanged legacy test was run
with a time limit and no robot/bus imports; its pose output drifted while
printing. Because it repeatedly uses a cached `_input_report`, printed
output alone is not a freshness guarantee. Independent raw HID reads
confirmed changing full-report timers during the comparison.
The daemon's stop also exposed a kernel-side LED work flush hang:
`joycond` remained in uninterruptible sleep under `brightness_store` →
`flush_work`, despite systemd's stop/kill request. This is recorded separately
from a lost radio connection. At that stage no ELF reboot or USB servo reset
had been attempted; the subsequently approved restart is recorded below.
The targeted Bluetooth USB-interface unbind at `1-1.1:1.0` also blocked in the
kernel. The servo adapter is on sibling interface `1-1.3:1.0`; it was not
unbound or reset. Preserve that distinction when recovering the board.
After correcting report setup and restoring the scoped input ACL, a
60-second input-only check passed without a missing-report error. A later
180-second check received no fresh samples, leaving connection stability
unqualified at that stage. A later read-only servo identity check also timed out, despite
the operator confirming motor power remains on. The newer ACK-checked
candidate was staged, but was not promoted over the last verified installed
binary while servo status is unavailable. No physical motion grant was issued.
The input-only check detected ZL press/release and thumbstick changes, but
the initial direction sequence produced only nonpositive axis values and
an off-center resting X reading. Those observations do not verify all four
directions. Do not widen the deadzone, learn a new neutral at startup, or
enable motion merely to hide this symptom. Verify the physical thumbstick
and its calibration in the monitor first. No physical joystick session was
started during these input checks.
The [joystick qualification record](evidence/e1-neck-joystick-20261125.json)
separates software regressions and two Linux ASan transport checks from
physical input and actuation qualification. Deployment
also ran the native ELF joystick simulation and read-only servo status.
For independent software/transport qualification while hardware is unavailable,
`moon run scripts/deploy_neck_control.mbtx SOCKET --stage-only` builds the
candidate and runs simulations and both ASan harnesses without opening the
servo port or changing the installed binary. Normal deployment still requires
a successful read-only hardware status check before promotion.

### Recovery after the approved ELF restart

The operator authorized restarting ELF on 2026-11-25. Filesystem sync
completed, but `/sbin/reboot -f` also entered uninterruptible sleep. A
privileged kernel emergency restart then recovered the board; this follows
the kernel's [SysRq restart mechanism](https://docs.kernel.org/admin-guide/sysrq.html).
The boot ID changed from `dc24ab1b-ae5f-4a3a-844f-c2900a0c2fa9` to
`50d0df1e-349a-4215-88e7-5bbd035a7303`. The blocked daemon/reset processes
were gone, `joycond` was disabled/inactive, and initial load fell from about
11 to 0.08. Wi-Fi returned at the existing address without reconfiguration.

Read-only servo checks recovered immediately: pan position/goal 1927/1927,
tilt 2052/2047, both torque enabled, speed 20, acceleration 3 and torque limit
300. No position, profile or torque writes were sent. The ACK-checked
candidate was then deployed through the normal verification path; both ASan
harnesses and native simulations passed, and its audit contained 49
cumulative READ packets and zero WRITE packets. The installed binary SHA256
was `a044ac56959ff491afab730d4682f8e0c7409e3cbc4be6681b3b1a94ad2c20f5`.
The controller does not auto-start a physical session after reboot. A fresh
Joy-Con connection/stream check and neutral measurement followed this recovery.

### Explicit stick calibration and Bluetooth compatibility

After the restart the operator swept the small thumbstick around its full
travel twice and released it. Factory-normalized input reached X
[-1000, 480] and Y [-1000, 1000], establishing both signs on both axes.
The operator had explicitly confirmed the untouched physical center. Its
measured X remained near -225 rather than zero. This is an input offset,
not a reason to change any servo neutral or widen its travel envelope.

The initial confirmed calibration used X minimum/center/maximum
-1000/-225/500 and Y -1000/0/1000. After another reconnect, the kernel and raw
HID reports instead settled at normalized X 0. The old offset would interpret
this as 31% right. The operator explicitly confirmed the small thumbstick was
untouched and physically centered again; `config/e1-neck-left-joycon.json`
temporarily recorded X -1000/0/500. A later reconnect again reported the
original cluster near -225. During the first physical trial, a transition to
raw-normalized zero caused small unintended rightward target steps under that
old offset. The current fixed center is -100: both explicitly observed resting
clusters [-250,-210] and [0,20] fit inside its unchanged 20% deadzone. The raw
neutral band moves from [-380,-80] to [-280,20], retaining the same 300-unit
width. This is an explicit calibration correction, not startup learning or a
wider deadzone. Regressions check both clusters and unchanged servo neutrals.
Deployment installs it at `/home/elf/moonrobo-neck/joycon-calibration.json`.
MoonBit maps each half-axis separately around that fixed center and saturates
input travel. It validates controller identity, explicit neutral confirmation,
ordered bounds, minimum half-span and unchanged kernel ranges. Physical
execution rejects missing or invalid calibration before opening UART. The
monitor may use an explicitly unconfirmed factory mapping when the file is
absent. Calibration is loaded once per input open; it is never learned from
an arbitrary startup pose. Servo goals, neutral values and limits are unchanged.

The host's Bluetooth alias is now `Nintendo-ELF-Neck` and HCI link policy
is `RSWITCH` without SNIFF. These are compatibility workarounds, not an
isolated root-cause finding: alias, link policy and output pacing changed
together. See the [firsthand Joy-Con investigation](https://blog.fyralabs.com/your-joy-cons-are-vibrating-themselves-to-death/),
[BlueZ link-policy interface](https://github.com/bluez/bluez/wiki/hcitool), and
[SDL's Bluetooth output timing warning](https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/SDL_hidapi_switch.c).
The Linux hostname, Wi-Fi and robot address are unchanged.

`config/moonrobo-joycon-radio.service` is installed and enabled on ELF as a
oneshot service. It checks the commissioned Intel AX200 USB vendor/product,
then applies the alias and default link policy after Bluetooth starts. It
also follows explicit Bluetooth-service restarts, which reset HCI policy.
It does not start a joystick session or touch a servo. `joycond` remains disabled
so it cannot mask input ACLs or enter its earlier LED-work hang again.

An initial compatibility check hit one 100 ms reader timeout while the
Bluetooth link stayed connected; fresh reports resumed after the input-only
monitor reopened. This was not evidence of a radio disconnect. The reader
budget was subsequently changed to 125 ms, covered by a delayed-report
transport regression. The 150 ms input-to-dispatch deadline, terminal physical
session faults and prohibition on automatic actuation reconnect remain intact.

The Bluetooth-qualification deployment passed 31 native MoonBit tests and both Linux ASan
transport harnesses, including input calibration rejection and paced HID
output checks. Read-only deployment verification contains 69 cumulative READ
packets and zero WRITE packets. Its binary SHA256 was:
`fc4737530b4113b102eaf47c594c7e7acb63535ed6720213f7f643720b14cb97`.
The qualification record below distinguishes the final live-stream result
from these software checks. No physical joystick session or new neck motion
was requested during recovery.

The five-minute 125 ms-budget check **failed**: 164 logged live samples
spanned 167,782 ms, then the reader lost its heartbeat and could not obtain
setup acknowledgements. Calibrated neutral stayed X [-21, 15], Y [0, 0].
An independent two-second raw HID read returned zero bytes even though BlueZ
still reported connected. The kernel logged repeated dropped IMU reports.
Wi-Fi was on 5 GHz, and both servos still responded with unchanged targets.
This is not a passing stability qualification and must not enable motion.

The next isolated transport experiment used BlueZ `UserspaceHID=true`
instead of the board's default kernel HIDP path; `/dev/uhid` is available.
`config/moonrobo-joycon-input.conf` retains `ClassicBondedOnly=true`.
The original input configuration is backed up at
`/etc/bluetooth/input.conf.before-moonrobo-20261125`.

After the operator woke the controller again, its HID device appeared under
`/sys/devices/virtual/misc/uhid/0005:057E:2006.0004`, confirming the transport
change was active. The five-minute input-only check **passed**: 292 logged
samples spanned 299,303 ms, with one input open, zero waiting errors and no
monitor reconnect. Calibrated X stayed [-24, 20] and Y [0, 0], inside the
unchanged neutral deadzone. The [retained raw log](evidence/e1-neck-joycon-uhid-20261125.jsonl)
can be rechecked with the qualifier below. Use `stdbuf -oL` before the native
monitor command when watching redirected output live, to avoid mistaking
buffered stdout for current input state.

Post-check read-only status still showed pan position/goal 1927/1927 and
tilt 2052/2047, with the same bounded holding profile and no servo errors.
The audit contained 81 cumulative READ packets and zero WRITE packets.
The radio-settings service remained enabled/active and the connected HCI
policy was RSWITCH. Keep userspace HID for this commissioned setup. This
passing finite check improves the evidence over the failed HIDP run; it
does not isolate every failure cause or establish indefinite Bluetooth
reliability. Physical execution remains inactive until its existing exact
motion receipt is supplied; this check did not start a motion session.

Later, input setup failed again after an idle period, and another fresh
connection stopped providing reports while trial preparation was in progress.
Independent raw HID reads returned no bytes. The passing five-minute run must
not be described as a permanent Bluetooth fix. A physical trial still requires
fresh input admission and terminates on any report loss, without reconnect.

### Preparing an explicitly authorized joystick trial

The actuator CLI's read-only `preflight` command wraps a normal checked
`Status` result with source epoch timestamps taken before and after UART
observation. `scripts/prepare_neck_joystick_trial.mbtx SOCKET APPROVAL_SOURCE`
prepares one exact two-minute `Joystick(120)` trial through the existing
MoonRobo host API's dry-run, approval and evaluate endpoints. It never invokes
physical execution. The required local JSON source records the actual current
operator request, `operator_authorized: true`, `action: ["Joystick", 120]`,
`neck_profile_version: "2"` and `servo_speed_limit: "50"`;
do not create that record without the operator's authorization.

The helper saves the actual completed MoonBit simulation, narrow robot
profile, operator source, checked servo observations, API responses, durable
dry-run/approval records and ready receipt together under
`_build/neck-control-elf/trials/INTENT_ID/`, then copies that review bundle to
ELF. Evaluation uses the timestamped source observation at its recorded time,
with its conservative source age bounded by the whole UART observation.
SSH round-trip duration is recorded separately rather than represented as
fresh servo feedback. The existing 60-second ready-receipt expiry and on-board
150 ms feedback/input guards at every physical write remain unchanged.
This tool does not relax the gate, expand the motion envelope, or auto-clear
fault markers. Only the existing `execute` command consumes the one-use intent.

### XLeRobot comparison and minimum-speed correction

The installed working reference was inspected without starting it:
`/home/elf/lerobot/examples/7_xlerobot_teleop_joycon.py`, its smooth two-wheel
variant, `/home/elf/lerobot/src/lerobot/robots/xlerobot/xlerobot.py`, the Feetech
driver and `/home/elf/.cache/huggingface/lerobot/calibration/robots/xlerobot/my_xlerobot.json`.
The source assigns the left D-pad to the head, with increments of 2 normalized
units (about 21–22 encoder ticks with the installed calibration), not exactly
2 degrees. `use_degrees` defaults to false. The direct example declares `FPS=30`
but does not apply a loop rate limiter, so its actual frequency is unmeasured.
Analog input serves the arms and ZL the left gripper. The
executable head assignments are up -> ID 8 positive, down -> ID 8 negative,
left -> ID 7 positive and right -> ID 7 negative. Some adjacent comments
contradict those assignments. Current physical directions still need visible
qualification on the transferred assembly; do not infer them from comments.

The old driver sets head P/D/I to 16/43/0, matching actual readback. Its
head action path writes goal positions without imposing the new speed value
20. Its startup zeroing, unrestricted deltas and torque cleanup are not reused.

The [read-only factory capture](evidence/e1-neck-factory-20261125.json) shows
both motors have phase 12 and factory bytes 80–86 `[1,20,50,1,65,50,1]`.
FEETECH's [STS memory-table reference](https://ftservo.github.io/ftservo-wiki/reference/parameter/memory-sts/)
explains the phase-dependent units and minimum physical speed increment.
With this measured factor and minimum, 50 is the minimum usable fine speed
setting, approximately 4.4 degrees/second. The former setting 20 was below
that minimum; a numeric target-slew limit was incorrectly presented as a
physical speed guarantee. The setting was unsuitable, but is not established as
the sole explanation: corrected-profile tests below also failed visible
qualification and one stopped on feedback velocity +100.

Profile v2 uses servo speed 50 while retaining one-tick steps at intervals
of at least 50 ms, fixed pan/tilt bounds, torque 300, acceleration 3 and the
raw feedback velocity fault threshold of 60. A new factory fingerprint check
precedes every non-release motion operation. Ready receipts must now match
the exact action, profile version and speed value; old profile approvals
cannot be reused. Read-only status recognizes the known legacy 20 and new 50
holding profiles so inspection itself does not alter a motor. The `configuration`
command reads fixed identity/factory/feedback registers only and is available
while a motion fault is latched.

Two profile-v1 physical trials did not pass visible-movement qualification.
The first stopped on ZL release during a pending write, with no later writes.
The operator then confirmed bracket/cable clearance and its marker was archived.
The second stopped on tilt feedback velocity -100, exceeding the unchanged 60
guard. Subsequent readback held pan position/goal 1898/1893 and tilt 2048/2038.
The operator subsequently reviewed clearance and explicitly approved profile 2
with speed 50 and the unchanged velocity guard 60. The second marker was archived
under its intent directory before the new trial. Neither trial returned to a
stored center or performed cleanup position writes.

Deployment now copies only its explicit source/header bundle and verifies a
dedicated new READ-only audit, leaving historical motion audits intact. A full
ELF root filesystem interrupted linking before promotion; the installed binary
was preserved. A redundant agent-created decoded trace was moved to `/tmp`,
and downloaded apt installer cache was cleaned to restore working space.
The [physical-trial evidence](evidence/e1-neck-physical-trials-20261125.json)
records all four trials, the factory capture and the profile-v2 build.
That build passes 37 native regressions, both Linux ASan harnesses and a
dedicated four-READ/zero-WRITE deployment check. ELF root free space recovered
to about 794 MB.

Two profile-v2 trials then ran under the operator's approval. The first ended
cleanly holding after about 24 seconds, consistent with a Minus exit. Pan encoder
feedback changed from 1898 to 1908; the operator reported no visible movement.
A later five-second hold prompt was mistakenly issued after that session had
already ended and cannot qualify physical motion.

The second profile-v2 trial stopped after about 15 seconds when pan velocity
reported +100 with position/goal 1920/1924. Raw reply bytes `64 00` confirm the
decoded velocity. The preceding pan sample was 1918 at capture time 10214192;
the fault sample was 1920 at 10214254. That two-tick change over 62 ms is a
sampled average, not proof that the instantaneous velocity report is harmless.
No later write was recorded. The operator again saw a stationary bracket.
The latest fault remains latched at `/home/elf/moonrobo-neck/inflight-or-fault`,
with no new physical session active. No velocity threshold was raised.

The [full installed XLeRobot study](XLEROBOT_REFERENCE_STUDY.md) traces the input,
unit conversion, bus packets, inherited configuration, startup/reset, shutdown,
Bluetooth reader and related arm/base/camera paths. It corrects the earlier
degree/30 Hz assumptions and records source hashes. The old normalized zero
maps to raw 1988/2122, outside our current E1 bounds, and must not be replayed.
Old source behavior is a reference, not physical qualification of this transfer.

To qualify a five-minute untouched-neutral recording, save stdout from
`neck-control joystick-monitor 300`, then run
`moon run scripts/qualify_neck_joystick_log.mbtx PATH_TO_LOG`.
The qualifier requires one input open, no waiting errors, at least 280 logged
samples spanning 295 seconds, and both calibrated axes inside the existing
20% neutral deadzone. Logged heartbeat intervals are approximately one second;
they are not the per-report HID age. This is an input-only qualification,
separate from motion authorization and physical clearance validation.

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
