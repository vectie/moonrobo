# Host constant fragments

This package implements actual CPU/Double calculations and data updates from the
pinned Newton/MuJoCo-Warp constant pipeline. It uses `moonnum/geometry` for shared
vector, matrix and rotation operations. `moonnum/linalg` currently has no symmetric
eigensolver, so the physics-specific principal-inertia decomposition is local.
It does not initialize Python, a device, a physics model or a numerical backend.

`prepare_constants(CommandRequest{operation,parameters})` produces a
`moonrobo-host-constant-fragment-v1` result. Parameters decode to the public typed
records below. Direct functions return newly owned arrays; caller inputs are not
mutated. Unsupported dimensions, nonfinite inputs and unsupported geometry fail
before computation returns a result. The CLI must explicitly invoke these host
calculations; no migration check runs them.

| Operation | Payload | Actual computation |
| --- | --- | --- |
| `body` | `BodyUpdate` | Apply world/body mapping to mass, COM and optional gravity compensation; diagonalize the symmetric inertia tensor, sort moments descending, ensure a proper principal frame, normalize its MuJoCo wxyz quaternion |
| `subtree-mass` | `SubtreeRequest` | Initialize subtree masses from actual body masses and accumulate each child subtree into its parent in validated bottom-up order |
| `mean-inertia` | `MeanInertiaRequest` | Average the actual last entry of each CSR inertia-matrix row; `nv=0` returns the MuJoCo default one |
| `pair-properties` | `PairUpdate` | Apply optional world-major solref, friction solref, solimp, friction, margin and gap attributes while preserving absent fields |
| `geom-properties` | `GeomUpdate` | Update analytic-shape friction, solref conversion, optional solimp/solmix, size, pose, margin and gap |
| `reference-qpos` | `ReferenceRequest` | Deep-copy current coordinates, expand shared/per-world qpos0 as pre-pass inputs, and provide independent saved/restore host arrays |

The public geometry types are `moonnum/geometry.Vec3`, `Basis3` and `Transform3`.
`Quaternion` stores fields `w,x,y,z`. All array world rows must have consistent
cardinality. Body/geometry mapping `-1` preserves the existing sentinel row.
Optional pair attributes are flat world-major arrays, indexed with the explicitly
supplied `pairs_per_world`; unused source slots remain source slots. Under native
CCD, the incoming pair margin is suppressed and the compiled margin is retained,
while gap still updates. Analytic geom margins are explicitly set to zero in the
same mode. Mesh/heightfield corrections and SDF/flex geometry are rejected.

Newton's positive-format material conversion uses `timeconst=2/kd` and
`dampratio=(kd/2)*sqrt(1/ke)` when both gains are positive, otherwise `(0.02,1)`.
Raw solref preserves actual authored values, including MuJoCo's negative direct
format. No bounding radius is manufactured: the upstream update also leaves it
to MuJoCo.

Principal inertia uses a normalized symmetric 3x3 Jacobi calculation with a
bounded 64-iteration convergence check. It validates orthogonality, determinant
and reconstruction residual, then sorts moments and fixes handedness. Relative
asymmetry above `1e-12` is rejected; negative eigenvalues below `-1e-12` of the
tensor scale are rejected and smaller roundoff negatives become zero. Quaternion
sign is canonicalized to nonnegative w. Repeated eigenvalues admit multiple
equivalent frames. This preserves mathematical tensor reconstruction, and makes
no claim to match Warp `eig3` float32 eigenvectors or bits. Subtree accumulation
also has a deterministic host summation order rather than parallel atomic order.

The physical mean-inertia helper consumes an **already assembled** actual qpos0
mass matrix with authored armature. It does not subtract locking armature from
float32 data or pretend to generate that matrix. It requires compact CSR prefix
row addresses that exactly consume each world row, rejecting overlapping,
reordered, gapped or trailing storage. The full upstream pre-pass
temporarily replaces qpos, restores authored armature, runs kinematics/COM/CRB
and optional tendon armature, calculates the statistic, reinstates locking and
qpos, calls full `set_const_0`, then restores the physical statistic. Only the
explicit host coordinate copies and diagonal calculation are provided here.
`ReferenceQpos` owns host data; it never represents an active solver transaction
or restores device state or derived caches.

Full `set_const_0` remains outside this package: kinematics, composite-rigid-body
mass assembly, tendon armature, factorization/solve, body/DOF/tendon inverse
weights, tendon/equality/camera/light references, actuator acceleration and
dampratio resolution, connect anchors and final state/cache restoration still
need their real backend. The existing SDK context path remains active. Results
therefore carry `full_set_const_closure=false`, `device_state_modified=false` and
`runtime_equivalence_verified=false`.

Source attribution (Apache-2.0): Newton Developers, Newton commit
`71eeba16a717d4dcf0b9dd7056a7b6f863054dc3`, and MuJoCo-Warp 3.15.0.

| Pinned primary source | SHA256 |
| --- | --- |
| [Newton MuJoCo kernels](https://github.com/newton-physics/newton/blob/71eeba16a717d4dcf0b9dd7056a7b6f863054dc3/newton/_src/solvers/mujoco/kernels.py) | `9443b0e25753623c8433500eb595814fc47a5a9735270aa1b914f59b1d0d10de` |
| [Newton constants](https://github.com/newton-physics/newton/blob/71eeba16a717d4dcf0b9dd7056a7b6f863054dc3/newton/_src/solvers/mujoco/constants.py) | `c624e55e200cee139472953f528a68aba46e215f98572d3ea64884916f9368b4` |
| MuJoCo-Warp 3.15.0 sdist `mujoco_warp/_src/set_const.py` | `1a49523e5c6e5c12133dcb54bb7d3b44afa8e11e8477ad96eea8107d62ef608b` |

Relevant upstream definitions are `update_body_mass_ipos_kernel`,
`update_body_inertia_kernel`, `compute_physical_meaninertia_kernel`,
`update_geom_properties_kernel`, `update_pair_properties_kernel`,
`_set_const_0_with_physical_meaninertia`, `set_const_fixed`, `_compute_meaninertia`
and `_copy_qpos0_to_qpos`. Pending regression sources cover analytical principal
moments, sentinels, nontrivial body topology, CSR diagonal placement, margin/gap
behavior and host copy isolation. They have not been executed.
