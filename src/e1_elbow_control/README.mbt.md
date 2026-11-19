# E1 elbow commissioning paths

This package generates deterministic elbow references from a complete 24-record
hold frame. It is not a learned actor or a balance controller. Left elbow pitch
is SDK ID 3; right elbow pitch is ID 14. Every other motor-command field is
copied from the initial hold. Slot 23 is reserved, outside the 23-joint model.

`Path` supports a 15-second fold/return, a gentle 5° version, and a 180-second
90° fold/return. `DrumPath` supports four alternating 10° strokes and a raised
sequence: both targets to −90°, two alternating 30° drops per elbow to −60°,
then return to the captured starting targets. The raised reference has 8,551
samples: 60 seconds up, two seconds hold, four 16-second down/up strokes and
45 seconds return. It can wait for measured feedback before advancing.

Travel uses the intersection of the SDK and model elbow ranges, [−130°, 0°].
The 90° and dual-elbow paths use the existing 5° following tolerance; the gentle
5° path retains its 1° tolerance. These are commissioning test settings, not
vendor-certified limits. The raised path does not change gains or widen the
following check. Commands returning to their initial values do not establish
that the measured pose returned exactly.

The default standing assessment checks stationary joints. Explicit
`suspended=true` accepts measured settling at non-elbow joints while retaining
SDK absolute leg travel, motor fault, finite-value, packet continuity, freshness,
elbow travel and following checks. It does not establish standing balance.
All 22 non-elbow command records remain fixed in both profiles; physical leg
motion is a separate measurement.

The standing ankle filter confirms a suspicious isolated ankle sample against
the immediately following consecutive packet, within six milliseconds. The
suspect sample cannot update the baseline or release a target. Sustained drift,
partial recovery, velocity-corroborated motion, invalid samples, missing
recovery and broken continuity still stop the path. Suspended packet cadence
uses the separate 40 ms freshness deadline after a real 15.648 ms source pause
was captured. Raised ticks schedule from the actual previous tick to avoid a
catch-up burst.

`cmd/e1_elbow_shadow` is the receive-only file/packet replay and factory teaching
checker. `cmd/e1_commission` emits target JSON for a separately launched DDS
transport. Neither executable embeds a vendor command singleton. Deployment,
namespace tests and read-only mirroring are documented in
[deploy/e1](../../deploy/e1/README.md).

The [commissioning findings](../../docs/E1_COMMISSIONING_FINDINGS.md) document
the January protocol, decoding fixes, failed attempts, successful powered
trials and remaining handback limitations. The successful 19 November raised
retry checked 83,745 outbound frames / 2,009,880 motor records. Only the two
elbow targets changed. Those receipts demonstrate that captured trial, not a
general unattended operation or a verified hardware stop deadline.
