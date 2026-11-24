Run from the repository root after opening an SSH control connection to ELF:

```sh
moon run cmd/neck_camera --target native
```

Open <http://127.0.0.1:4195/>. The server binds only to this Mac's loopback
interface and forwards the D455 RGB feed through the existing SSH connection.
It does not provide motor controls or publish camera footage to a hosted site.

Optional positional arguments are the SSH control socket and the literal
`/dev/` camera path. Defaults are recorded in `main.mbt`; the camera uses its
stable V4L2 USB ID, not a changing `/dev/videoN` number. The existing board-side
FFmpeg installation captures 640 × 480 RGB at 15 fps. Capture reconnects after
failure and shares one source between viewers; slow viewers receive the latest
frame without an unbounded queue. `/status` reports source frame freshness,
not measured camera-to-screen latency. `/snapshot.jpg` returns a fresh frame or
HTTP 503. UI snapshots save the currently displayed canvas, including when paused.

The stream is MJPEG for this initial LAN viewer. It is not a low-latency VR
transport. The page shows camera direction; the camera cannot see its own neck
and cannot establish mechanical clearance.
