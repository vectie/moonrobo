# Native producer convergence fragments

This package executes CPU/Double numerical algorithms in MoonBit, with the shared
Moonnum `geometry.Vec3` representation for cost/gradient/Hessian triples. It does
not invoke Python, an SDK, CUDA or a full physics solver. Original upstream and
first-party implementations remain in place.

`CommandRequest` derives `FromJson`. `prepare(request)` accepts explicit operations
`linesearch` and `convergence` and returns the actual computed result with source
identity and scope fields. Typed callers can use `linesearch(LineSearchRequest)`
and `convergence(ConvergenceRequest)` directly. No operation runs merely by
importing the package. JSON parameters, world records, rows and CG vectors reject
unknown fields, so an unsupported cone or algorithm option cannot be silently
discarded by decoding.

## Implemented algorithms

The pyramidal line search follows MuJoCo-Warp 3.15.0
`_linesearch_iterative_kernel`: Gaussian and equality quadratic accumulation;
frictionloss piecewise linear/quadratic costs; unilateral active/inactive costs
shifted against alpha zero; derivative acceptance/noise floor; initial Newton
step; Newton candidates at both bracket ends and midpoint; lowest-cost converged
candidate selection; ordered bracket replacement including minimizer crossing;
runtime early exit; and alpha/improvement, qacc, Ma and Jaref updates. The supplied
`ls_iterations` is a maximum budget. It never replaces the convergence condition
with a fixed number of iterations. Exhausting that budget sets bit 1024 while
preserving existing overflow bits. Already done worlds retain their outputs;
nonincremental calls retain the existing `ls_exhausted` flag. Rows beyond
`min(njmax, rows.length())` retain their existing Jaref values.

One convergence transition follows `_solve_done` for Newton and
`_solve_beta_finalize_tiled` for CG, including the distinct Newton decrement gate,
scaled improvement/gradient gates, CG nonnegative Polak–Ribiere beta, one niter
increment per active world, iteration-limit overflow bit 512, and exactly one
decrement of nsolving for a newly completed world. `continue_condition` is the
actual resulting `nsolving > 0`; callers must supply fresh real solver results
before another transition. Already done worlds are skipped. The request must
state nsolving equal to its unfinished-world count, and an unfinished world's
niter must be below its iteration limit.

## Inputs and limits

All matrix/Jacobian products, gradients, preconditioned gradients, inertia,
diagonals, constraint rows and existing outputs must be actual supplied data.
Arrays are per world; the caller resolves upstream modulo-world broadcasting.
Equality rows precede frictionloss rows, followed by unilateral/pyramidal rows.
There is no elliptic-cone operation, Jv/Mv assembly, gradient/Hessian computation,
factorization, CG search-vector update, contact generation, device buffer mapping,
GPU reduction or connection to the live SolverContext. This package therefore
does not complete the solver closure or remove the live SDK solver dependency.

Finite values, positive nv/meaninertia, nonnegative tolerances/diagonals/friction,
shape consistency and valid iteration states are checked. Individual dimensions,
row counts, world counts and iteration budgets are capped at 1,000,000. A
nonfinite intermediate fails explicitly. These checks constrain the supported
domain; they are not upstream nonfinite propagation compatibility. `safe_div`
replaces only an exactly zero denominator by MuJoCo's `mjMINVAL = 1e-15`. The
upstream float32-derived `_ALPHA_NOISE_EPS = 8 * 1.1920929e-07` is intentionally
preserved. Sequential Double reductions differ from Warp's float32 tile reduction
order; numerical/learning-result equivalence remains unverified.

## Source identity and pending verification

The source is the official `mujoco-warp==3.15.0` source distribution recorded by
the repository's APIC source evidence, not the version currently installed in a
Python environment. Relevant source SHA-256:

| File | SHA-256 | Symbols |
| --- | --- | --- |
| `mujoco_warp/_src/solver.py` | `d26300bbe665aa182a0afc30c3d1ee43c38b8b14841e2e61544c92dea97af916` | `_in_bracket`, direct/friction evaluators, `_linesearch_iterative_kernel`, `_solve_done`, `_solve_beta_finalize_tiled` |
| `mujoco_warp/_src/math.py` | `d08e978993c3d3b5d3f16cb96af94beff519a60a5ea827134b388f30c3a6756c` | `safe_div` |
| `mujoco_warp/_src/types.py` | `5ff63b8186bafba2e2d51d5aae84875fb289411d9984f4e06b51813ea088491b` | `OverflowType`, `MJ_MINVAL` |

`convergence_wbtest.mbt` contains eight pending regression test sources covering
initial acceptance, active-set crossing with an actual bracket iteration, overflow
and exhausted rays, done-world preservation, friction and unilateral branches,
Newton versus CG gates/beta, exact-once loop counter transitions, and malformed
loop/vector inputs. Only static check/info/fmt are permitted for this migration
round. No tests, numerical examples, SDK/GPU/JIT runs or equivalence checks have
been executed.
