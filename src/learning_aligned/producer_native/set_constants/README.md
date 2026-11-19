# Rigid host reference constants

`prepare_set_constants(CommandRequest)` performs actual CPU/Double rigid-body
calculations at the supplied `qpos0`. It is a further numerical subset of the
MuJoCo-Warp 3.15.0 reference-constant pipeline, using shared `moonnum/geometry`,
checked dense `moonnum/linalg.solve`, and the existing `constants` helpers.
No Python, SDK, native physics model or GPU context is initialized.

The request has `models`, `qpos0`, `current_qpos` and `features`. Models are either
shared (one entry) or one per world, so actual mass/COM/inertia differences can
be supplied. A `RigidModel` contains `bodies` and authored physical `armature`.
Each `Body` has `parent`, parent-relative `pose:Transform3`, `mass`, body-local
`com:Vec3`, body-frame COM `inertia:Basis3`, and an optional `Joint`.
The world body zero must be fixed, massless, identity-authored and have zero
inertia. Body indices must follow MuJoCo's parent-before-child order.

Supported joints are fixed (`joint:null`), hinge, slide and one free root. Joint
fields are `kind`, `qpos_adr`, `dof_adr`, body-local `anchor` and normalized `axis`.
Hinge/slide have one coordinate and DOF. Free joints have seven coordinates
`x,y,z,w,qx,qy,qz` and six DOFs (world linear, body-local angular). Their body
pose is the actual free coordinate pose, overriding the authored parent pose.
All coordinate/DOF ranges must be disjoint and completely classified. Ball and
multiple-joint bodies require their actual adapters and are rejected.

The bounded host subset accepts up to 64 worlds, 256 bodies and 96 DOFs per
model. Singular/nonfinite mass systems fail through the checked shared linear
solver. `FeatureCounts` explicitly names `tendons`, `flex`, `mocap_bodies`,
`kinematic_bodies`, `equalities`, `cameras`, `lights` and `actuators`. Tendon
armature, flex, mocap and kinematic locking can change the core calculation and
must be absent. Equality, camera, light and actuator-specific constants are
reported as omitted even when their counts are nonzero. No full completion is
claimed when those stages are absent.

Computed outputs per world are:

- Actual rigid FK, body COM and world-frame inertia at qpos0. Hinge/slide FK uses
  the original anchor-corrected rotation and coordinate-minus-reference rule;
  qpos0 is both evaluation and reference coordinate for constant recomputation.
- Ancestor geometric Jacobians at each body COM. Free angular axes rotate with
  the root body; free linear axes remain in the world frame.
- A genuine generalized mass matrix from rigid-body kinetic energy,
  `sum(m JvᵀJv + Jwᵀ I_world Jw) + authored_armature`, and its actual checked
  dense inverse. This is a CPU reference assembly, not an invocation of
  MuJoCo-Warp's packed CRB, factorization or tiled/sparse solve implementation.
- DOF inverse weights from inverse-matrix diagonal entries, with the original
  free-joint translation/rotation groups averaged separately.
- Body inverse weights from mean diagonals of `J inv(M) Jᵀ`. Static bodies stay
  zero; translation/rotation use the original cross-component fallback at
  `mjMINVAL=1e-15`.
- Subtree mass, COM and composite inertia about each subtree's own COM, with
  correct parallel-axis shifts for both own-body and descendant inertia.
  This named representation differs from raw MJWarp `cinert/crb` storage, which
  expresses inertia about a root subtree COM.
- Mean inertia from the actual assembled matrix diagonal, reusing the checked
  compact-CSR diagonal helper. Zero DOFs have the original default statistic one.

`current_qpos` is copied using `constants.ReferenceQpos`. Result fields
`saved_qpos`, `reference_qpos` and `restore_qpos_input` are independent host data.
They do not represent an active solver transaction or modify/restore GPU state,
solver caches, armature, actuator bias parameters or renderer state.

The output format is `moonrobo-rigid-host-set-constant-subset-v1`. It explicitly
sets `full_set_const_closure=false`, `mjwarp_factorization_executed=false`,
`device_state_modified=false`, `active_solver_transaction=false` and
`runtime_equivalence_verified=false`. Complete `set_const_0` still needs real
tendon, equality/connect, camera/light, actuator acceleration/dampratio and final
state/cache restoration stages. This package does not replace the SDK context
path and does not substitute CPU `mj_step` for the original GPU solver.

CPU/Double eigenframes, dense LU and summation order differ from Warp float32
eigendecomposition, atomics and packed/tiled factorization. The body inertia
validator's documented tiny PSD roundoff handling and bounded negative quadratic
form roundoff handling do not establish numerical or scientific equivalence.
All results await the deferred differential comparisons.

Primary source attribution is Apache-2.0, Newton Developers. The pinned Newton
integration is commit `71eeba16a717d4dcf0b9dd7056a7b6f863054dc3`; the original
physical-mean-inertia pre-pass still requires authored-armature reference mass
assembly before locking is restored. MuJoCo-Warp 3.15.0 source identities:

| File | SHA256 | Audited definitions |
| --- | --- | --- |
| `mujoco_warp/_src/smooth.py` | `6268f0e1b6cb4c9ec6bbd3aa29828dfb36224efb2a3a3e1f54e5f87b6623fdef` | `_kinematics_branch`, `_compute_body_inertial_frames`, `_subtree_com_init/_acc/_div`, `_cinert`, `_cdof`, `crb` |
| `mujoco_warp/_src/set_const.py` | `1a49523e5c6e5c12133dcb54bb7d3b44afa8e11e8477ad96eea8107d62ef608b` | `set_const_fixed`, `set_const_0`, `_compute_body_jac_row`, `_finalize_dof_invweight0`, `_finalize_body_invweight0` |

The exact published source distribution is retained read-only under
`/tmp/mujoco_warp-3.15.0`. `mjMINVAL` was also checked against the genuine installed
MuJoCo `mjtnum.h`. Pending source regressions cover analytical hinge/slide/free
mass and inverse weights, nonzero anchor FK, free COM coupling, inverse residual,
composite parallel-axis inertia, invalid layouts and singular systems. No tests,
numerical examples, simulation, SDK/GPU work or compilation/export were run.
