# Independent MuJoCo native collision

This package connects MoonBit to the real **MuJoCo 3.3.7 C collision API** using
an explicit native adapter and explicit MuJoCo shared library. It accepts a
**precompiled MJB**, copies actual MuJoCo-order `qpos`, and calls
`mj_resetData → mj_kinematics → mj_comPos → mj_collision`. It does not compile
MJCF, call `mj_step`, build a Newton model, execute Warp/CUDA, or generate APIC.

The actual MuJoCo implementation supplies rigid primitive, box/convex mesh and
heightfield collision according to the MJB's geometry, contact pairs, flags,
filters, margins, and solver parameter mixing. Mesh means MuJoCo's native mesh
collision semantics (generally convex hull), not arbitrary nonconvex triangle
collision. This route is **CPU/Double** with MuJoCo **3.3.7**, independently of
the MoonBit typed CUDA lowerer's MuJoCo-Warp **3.15.0 / Warp 1.17.0** pin.
No cross-backend or numerical equivalence is claimed.

`Config` is FromJson / ToJson:

| Field | Meaning |
| --- | --- |
| `adapter` | Explicit adapter shared-library path |
| `mujoco_library` | Explicit MuJoCo 3.3.7 shared-library path |
| `mjb` | Existing binary model path, with native embedded assets |
| `qpos` | Array of finite Double values in the MJB's actual `nq` order |
| `contact_capacity` | Nonnegative maximum report size; exceeding it is an error |
| `output` | Fresh output directory, never an existing directory |

`run(Config) -> Json` resolves regular input files, hashes them, calls the
explicit native collision session, rechecks those hashes, and then writes
`input-qpos.json`, `contacts.json` and `receipt.json` (last). The receipt contains
actual input and output SHA256 values. Native transitive dependencies are not
attested. Failed collision or changed input bytes publish no output directory;
filesystem failures during publication can leave a partial directory with no
completed receipt.

`Session::open(adapter, library, mjb, contact_capacity)`, `collide(qpos)` and
`close()` expose the same lower-level native path. Session owns the C object,
model/data and both loaded libraries, with deterministic close and a GC
finalizer. Close is idempotent. Calls on a closed or failed session reject.
Sessions are synchronous and must not be accessed concurrently from native
threads. Public open and the C loader both reject empty/NUL-containing paths.
Use `run` for canonical regular-file identity and hash receipts.

The adapter requires genuine headers with `mjVERSION_HEADER == 337` and
`sizeof(mjtNum) == sizeof(double)` at compilation. It calls `mj_version()` and
requires runtime **337 before accessing model/data structs**. It dynamically
loads genuine C symbols; there are no layout replicas or Python imports.
Configure the CMake directory with the real `MUJOCO_INCLUDE_DIR`; no SDK is
downloaded or installed by the build. This does not make MJB portable across
MuJoCo versions: the runtime must itself accept the supplied MJB.

Plugin-bearing models, flex and SDF are rejected; this adapter intentionally
omits `mj_flex`. Plugin rejection is after MJB loading, so this is not a promise
that native deserialization cannot touch a registered plugin. Use trusted
native libraries and MJBs; upstream native fatal error/abort behavior cannot be
converted to a MoonBit exception by this adapter. Model body counts are bounded
to avoid the pinned driver's signed intermediate pair-count overflow.

Free/ball joint quaternions must already be unit **wxyz** (squared norm within
1e-8 of one). They are not silently normalized. Zero-length `qpos` is valid
only if actual MJB `nq` is zero. Nonfinite inputs or exported scalar contact
fields reject. Native `CONTACTFULL` warnings and contact counts exceeding the
configured report capacity reject instead of publishing truncated contacts.
Other native warning counts and info are exported. Native contact and constraint
disable flags are preserved, so an intentionally disabled model can have zero
contacts. No solver constraints are constructed.

`contacts.json` contains `dist`, midpoint `pos`, all nine frame components
(normal first row, geom0→geom1), include margin, friction, solref/solreffriction,
solimp, dim, geom/flex/elem/vert IDs, exclude and EFC address for each actual
`mjContact`. Solver-only `mu`/Hessian fields are omitted because collision does
not compute them. Exported EFC addresses are the collision-stage values, normally
-1, and do not imply a prepared constraint solve. Collision sensors and Newton's
separate sensor-candidate semantics are not ported by this native path.

Static validation only: MoonBit check/info/fmt and `clang`/`clang++ -fsyntax-only`
against genuine existing MoonBit and MuJoCo 3.3.7 headers. No adapter build/link,
load, model initialization, algorithm execution, test, GPU, SDK initialization,
NVRTC compilation or sample run has occurred. Pending later machine time:

- valid primitive/box/convex mesh/hfield MJB differential contact/frame/material
  comparisons against the same native version, including filter/disable flags;
- unit quaternion/order, qpos length/nonfinite and zero-nq cases;
- header/runtime mismatch, missing symbol, invalid MJB, plugin/flex/SDF rejection;
- actual CONTACTFULL, report-capacity zero/overflow, finite output enforcement;
- close/finalizer/resource cleanup, repeated collision state reset, failed-session
  rejection and write-failure receipt behavior;
- explicit Newton↔MuJoCo state/model mapping before any cross-solver comparison.

Primary evidence is recorded in `sources.json`. Source inspection of
`mj_fwdPosition` establishes kinematics + COM frames before collision;
`mj_collision` accesses rigid geom poses and static body BVHs, while dynamic BVHs
belong to flex (rejected here). Camera/light, tendon and inertia stages do not
feed this rigid collision route. Original implementations are retained.
