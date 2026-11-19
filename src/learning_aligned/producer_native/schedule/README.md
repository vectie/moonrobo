# Fixed G1 producer schedule

This package moves the pinned host-side operation ordering to pure MoonBit. It
does not initialize an SDK, dereference pointers, launch a kernel, or substitute
an empty graph for a missing solver. `compile` validates observed manager facts;
the resulting nodes carry a strict predecessor dependency. The hybrid integration
can lower them through real upstream methods while native implementations arrive.
`validate_native_coverage` separately rejects incomplete implementation inventories.
Neither a schedule nor that source-level inventory establishes numerical parity.

The fixed profile uses one in-place state, internal MuJoCo contacts, one control
tick of 0.02 seconds, and four solver substeps of 0.005 seconds. The manager's
ordinary `step` wrapper is not part of the captured producer operation.

| Role | Ordered work |
| --- | --- |
| step | Position target; scene command submission; optional body-force staging; actual pre-actuator callbacks; optional adapter; actual post-actuator callbacks; four rounds of force restoration, state-force callbacks, full solver step and force clearing; actual post-step callbacks; sensors; publication |
| reset | Four masked state writers; reset position target; explicit selected-world solver reset with flags zero; guarded manager forward; publication |
| context | Actual model-change notification; guarded manager forward; publication |
| refresh | Guarded manager forward; publication |

The body-force staging copy occurs before callbacks. Every substep restores it
before state-force callbacks add forces. The actuator receives the full control
tick and uses copy-back rather than a state-buffer swap on the sole decimation
iteration. The fixed implicit-only G1 scene can genuinely have no global Newton
actuator adapter: collection command computation and submission still occur in
the scene-write operation. Observed callbacks and sensors retain their list order.

`ForwardBoundary` denotes the complete original guard, selected-world internal
reset, masked Newton FK, mask clearing, and dirty-state publication. It must not
be lowered to an unconditional MuJoCo full forward. `Publish` denotes scene data
update, explicit user-order refresh, and the root pose/COM velocity/joint position/
joint velocity reads; those getters can themselves resolve pending forward work.
Masked reset writers also invalidate caches and reset world/FK masks. Context
notification includes the original shape and body-inertial property updates and
solver-constant recalculation; recording only the flag value is insufficient.

The forward guard is `kinematics_dirty || transforms_may_change_on_graph_replay`.
When true, the original MJWarp reset delegate skips a missing world mask and
otherwise calls the real solver reset with flags zero. The FK delegate consumes
the actual world and articulation masks; existing masks are then zeroed and
`kinematics_dirty` becomes false. The external-replay flag remains intact. A
publication read may encounter this boundary again through upstream getters;
the integration must preserve that call and its guard rather than deleting it
as apparently redundant work.

Native operands bind a component view to its actual numerical owner, scalar type,
UInt64 address and exact byte capacity. The contracts package proves bounds and
alignment before this package compares native addresses. Implementation entries
must identify actual source bytes and entrypoints; the eventual lowering layer
must verify exported functions or compiled module signatures before registering
them. Missing solver/kernel/publication implementations remain explicit errors.

Audited primary source is IsaacLab commit
`46d6cc3d7b115906fad12efd372fbf69f4e3d3ed`:

- [Newton manager](https://github.com/isaac-sim/IsaacLab/blob/46d6cc3d7b115906fad12efd372fbf69f4e3d3ed/source/isaaclab_newton/isaaclab_newton/physics/newton_manager.py)
- [MJWarp reset specialization](https://github.com/isaac-sim/IsaacLab/blob/46d6cc3d7b115906fad12efd372fbf69f4e3d3ed/source/isaaclab_newton/isaaclab_newton/physics/mjwarp_manager.py)
- [Newton actuator adapter](https://github.com/isaac-sim/IsaacLab/blob/46d6cc3d7b115906fad12efd372fbf69f4e3d3ed/source/isaaclab/isaaclab/actuators/newton/adapter.py)
- [Articulation command adapter](https://github.com/isaac-sim/IsaacLab/blob/46d6cc3d7b115906fad12efd372fbf69f4e3d3ed/source/isaaclab_newton/isaaclab_newton/assets/articulation/actuator_control.py)
- [Articulation writers](https://github.com/isaac-sim/IsaacLab/blob/46d6cc3d7b115906fad12efd372fbf69f4e3d3ed/source/isaaclab_newton/isaaclab_newton/assets/articulation/articulation.py)
- [Publication and invalidation](https://github.com/isaac-sim/IsaacLab/blob/46d6cc3d7b115906fad12efd372fbf69f4e3d3ed/source/isaaclab_newton/isaaclab_newton/assets/articulation/articulation_data.py)
- [Collection computation](https://github.com/isaac-sim/IsaacLab/blob/46d6cc3d7b115906fad12efd372fbf69f4e3d3ed/source/isaaclab/isaaclab/actuators/actuator_collection.py)

Full solver operations remain tied to Newton commit
`71eeba16a717d4dcf0b9dd7056a7b6f863054dc3`,
[SolverMuJoCo](https://github.com/newton-physics/newton/blob/71eeba16a717d4dcf0b9dd7056a7b6f863054dc3/newton/_src/solvers/mujoco/solver_mujoco.py).
The test sources are pending execution until machine availability permits it.
