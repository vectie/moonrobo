# Native USD articulation IR and fixed G1 scene recipe

`articulation_ir(receipt)` decodes the `articulation_ir` emitted by the native
OpenUSD model adapter. `g1_plan(receipt, num_envs, self_collisions)` validates the
fixed G1 assumptions and produces a `ScenePlan`. Neither function imports Python,
initializes a solver, reads USD through Python, or finalizes a Newton model.

The C++ extraction lives in `native/usd_scene.hpp` and is compiled into the
existing optional `moonrobo_prepared_usd` adapter. It uses actual OpenUSD
`UsdPhysics`, `UsdGeom` and `UsdShade` APIs. The adapter requires an OpenUSD build
without Python support; see the adjacent model package for CMake instructions.

The typed IR records:

- Composed rigid-body transforms, enabled/kinematic flags, velocities and
  authored mass/COM/inertia properties. Missing authored mass properties remain
  null; automatic mass and inertia inference is not fabricated.
- Joint body relationships, local frames, axes, limits, drives and collision
  flags. Revolute limits and angular velocity retain USD degree units.
- Collision meshes with authored polygon topology, holes and orientation;
  cube/sphere/capsule/cylinder/cone dimensions; body attachment, collision
  approximation and composed physics material binding.
- Physics materials, filtered pairs and articulation-root paths. Authored
  Newton/Mjc/Physx extension attributes are retained as type-tagged text for
  inspection, without claiming to apply their resolver semantics.

Transforms are row-major `GfMatrix4d` values using USD's row-vector convention.
Quaternions are wxyz. Distances, masses and inertia are retained in stage units.
The G1 recipe currently requires metre/kilogram units and a Z-up stage. Extraction
uses `UsdTimeCode::Default`, includes instance proxies, and is scoped to the
selected default-prim subtree. It does not export an arbitrary animated USD
scene, visual renderer data or unrelated roots.

`g1_plan` binds exactly the 29 enabled canonical revolute joint names to their
actual USD paths and reuses `@aligned`'s motor map and default positions. Its
actuator order is canonical, distinct from USD traversal order and any future
Newton builder order. The real SDK order must still be checked after import.

The public `ScenePlan.recipe` JSON schema is
`moonrobo.aligned-fixed-g1-scene-recipe.v1`:

| Field | Contract |
| --- | --- |
| `root_pose` | `position:[0,0,0.76]`, `quaternion_wxyz:[1,0,0,0]` |
| `root_joint_defaults` | Canonical `[{name,position,velocity}]`, radians and radians/s |
| `motors` | Canonical `[{name,actuator_name,effort,velocity,stiffness,damping,armature,action_scale}]` |
| `robot` | Prim pattern, gravity/damping/contact-sensor overrides, self-collision flag and 0.9 soft-limit factor |
| `scene` | Environment count, zero spacing, replicated physics |
| `solver` | 0.02 s control, 0.005 s physics, four substeps, 500 joint/128 contact limits, pyramidal cone, implicitfast integrator and explicit graph/contact flags |
| `ground` | `/World/ground`, upstream `GroundPlaneCfg`, empty explicit overrides |

The ground record preserves the original call's dependence on the pinned
upstream `GroundPlaneCfg` defaults. It does not assert those defaults have been
independently reproduced. The zero-spacing origin policy does not reproduce
upstream collision-world grouping.

The remaining builder boundary is explicit. At the pinned revisions, the
[IsaacLab manager](https://github.com/isaac-sim/IsaacLab/blob/46d6cc3d7b115906fad12efd372fbf69f4e3d3ed/source/isaaclab_newton/isaaclab_newton/physics/newton_manager.py)
orders Newton and Physx schema resolvers and adds Mjc when the solver registers
its attributes. Its clone plan feeds the actual Newton builder; the backend
then finalizes device arrays. The
[Newton USD importer](https://github.com/newton-physics/newton/blob/71eeba16a717d4dcf0b9dd7056a7b6f863054dc3/newton/_src/utils/import_usd.py)
also handles ordering, frame rebasing, mesh approximation and solver-specific
properties. The
[builder](https://github.com/newton-physics/newton/blob/71eeba16a717d4dcf0b9dd7056a7b6f863054dc3/newton/_src/sim/builder.py)
performs shape/inertia processing and array finalization. These operations are
not replaced by raw schema extraction. Their Python APIs are not a C ABI.

Accordingly `unsupported_features` always records the unresolved importer and
finalization semantics, and both IR and recipe report `native_builder_ready`
as false. `newton_model_constructed` and `physical_equivalence_verified` are
also false. The hybrid producer can use the MoonBit recipe for first-party
configuration while retaining the actual upstream builder until its native
replacement is implemented and differentially verified.

Only MoonBit static checking and source/header API inspection have been done.
No USD stage, model, compiler, SDK, GPU, export or tests were executed. A complete
configured Python-free OpenUSD build is still required to compile-check and
later validate the extended native adapter.
