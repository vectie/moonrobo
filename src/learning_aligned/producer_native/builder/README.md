# Prepared rigid-tree arrays in MoonBit

This package implements actual CPU/Double topology, kinematics, world indexing
and authored-inertia preparation. The result contains numerical arrays, not
just an operation inventory. No Python, CUDA, Warp runtime, USD loader or
solver is called by the package.

`prepare(plan, worlds)` consumes the real native `scene.ArticulationIR` and
the fixed scene plan's canonical motors/default positions. Each `WorldPlacement`
is a proper rigid offset composed with the recipe's initial root pose. The
package computes forward kinematics from the USD joint frames at the configured
default joint positions. Thus `body_q` and `joint_q` describe the same initial
reset state. It does not mix authored USD rest-body poses with nonzero reset
joint coordinates. All initial velocities are explicitly zero, matching the
supported first-party reset configuration.

`prepare_from_receipt(request)` offers a JSON-friendly API. Its `PrepareRequest`
contains `usd_receipt`, `num_envs`, `self_collisions` and `placements`. Each
placement contains `position:[x,y,z]` in metres and
`quaternion_wxyz:[w,x,y,z]`. Exactly one placement is required per environment;
an identity placement preserves the recipe's initial root pose. This entrypoint
first calls the real scene package's G1 receipt validation, then computes the
prepared arrays. It performs no filesystem operations; the command layer owns
fresh-output creation and input/output SHA receipts.

The implemented subset has one floating root and a connected directed tree of
enabled fixed/revolute joints, with body0 as parent and body1 as child. All
bodies must be dynamic and enabled. Proper unscaled rigid transforms and
metre/kilogram/Z-up units are required. The package rejects duplicate/multi-parent
edges, loops, hidden disconnected components, reversed/externally attached or
excluded joints, nonunit quaternions, reflection, shear, scaling and unsupported
joint types. Every revolute joint needs one explicit canonical actuator.

The result schema is `moonrobo.aligned-prepared-tree-arrays.v1`:

- Body arrays include source/body/world maps, flattened xyz+xyzw poses,
  flattened linear+angular zero velocities and optional authored mass properties.
- Joint arrays include pinned Newton type codes (`FREE=4`, `REVOLUTE=1`,
  `FIXED=3`), parent/child/world maps, anchor frames, axes, generalized positions
  and velocities, coordinate/DOF/axis prefix arrays with final sentinels,
  motor gains, armature and effort/velocity limits.
- Canonical motor indices map into each world's global joint, coordinate and
  DOF arrays. Articulation start/end indices delimit each cloned world.
- USD revolute limits convert degrees to radians. Unlimited limits remain
  `null` in the prepared arrays; they are not mislabeled as finite values or
  silently converted into a solver-specific maximum constant.
- Completely authored positive mass, COM, principal inertia and principal-axis
  quaternion produce the rotated full inertia tensor and its inverse. Physical
  triangle inequalities are checked. Missing values and USD inference sentinels
  remain absent; no guessed mass or identity tensor is inserted.

Rigid transforms, axis rotations, composition and vector operations use the
shared `moonnum/geometry` layer. No numerical work was executed during migration.

The source comparison uses Newton revision
`71eeba16a717d4dcf0b9dd7056a7b6f863054dc3`:

- [`_joint_plan.get_joint_order`](https://github.com/newton-physics/newton/blob/71eeba16a717d4dcf0b9dd7056a7b6f863054dc3/newton/_src/usd/_joint_plan.py)
  delegates directed-tree ordering and rejects reversed joints. This subset
  rejects merged joint pairs as well.
- [`topology.topological_sort`](https://github.com/newton-physics/newton/blob/71eeba16a717d4dcf0b9dd7056a7b6f863054dc3/newton/_src/utils/topology.py)
  visits children by source joint index; the MoonBit iterative DFS follows that
  accepted-tree ordering. The IR source order is not asserted equal to the
  OpenUSD physics parser's descriptor order until differential verification.
- [`_articulations`](https://github.com/newton-physics/newton/blob/71eeba16a717d4dcf0b9dd7056a7b6f863054dc3/newton/_src/usd/_articulations.py)
  inserts parent/child bodies in joint order and adds a floating base when no
  authored joint connects the root to the world.
- [`ModelBuilder.add_joint`, `add_joint_free` and cloning](https://github.com/newton-physics/newton/blob/71eeba16a717d4dcf0b9dd7056a7b6f863054dc3/newton/_src/sim/builder.py)
  establish the coordinate widths, xyzw convention, DOF ordering and nonnegative
  index offsets that this package prepares.

This is not complete Newton finalization. Shapes, ground, collision filters,
mesh cooking, density-based mass inference, schema-resolver precedence,
equality/mimic constraints, solver-specific attributes, actuator target modes,
constraint arrays, float32 conversion and device allocation remain unresolved.
The raw source IR retains their evidence. `mass_properties_complete` only means
all bodies supplied complete authored inertial data; it does not prove full
physics compatibility. `full_finalize_complete`, `newton_model_constructed`
and `numerical_equivalence_verified` are always false.

Meaningful pending test sources cover branched ordering/global world offsets,
FK consistency under a rotated clone, missing authored inertia, rotated inertia
and inverse inertia, and rejected cycles/parallel joints/reflections. Only
MoonBit check/info/fmt have been run. No tests, examples, array preparation,
USD/model conversion, SDK initialization, JIT, simulation or export was run.
