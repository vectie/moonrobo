# Physics-Derived Full-Body Reference Clips

Updated: 2026-10-23. Nine new successful thirty-second teacher trajectories now
provide physically feasible full-body reference data. Twenty-seven reapplications
of their original controls reproduce every state component exactly. A baseline
that commands the reference joint positions falls in all twenty-seven trials.
This closes a reference-data/feasibility slice; learned full-body tracking and
the matched world-model/PPO comparison remain outstanding.

SuperMimic Appendix A uses a full motion reference, future reference frames and
body/root tracking rewards. It explicitly treats low-gain position setpoints as
a torque proxy. The paper does not fully specify its per-frame encoder layout;
the representation below is an independent local design, not a claimed exact
reproduction. See the [paper](https://arxiv.org/pdf/2610.28480), pp. 13–15.

## Data And Reference Semantics

The [collection config](../examples/learning/g1-full-body-reference.json) fixes
reset 7300, thirty seconds, existing fall thresholds and replay origins before
collection. The selected [sustained privileged teacher](G1_LONG_BALANCE_DIAGNOSIS.md)
runs all nine training cases: stand, pose-offset and independent joint sines,
each at friction 1.0/0.8/0.6. All nine complete, supplying 13,500 transitions.
No prior audit/canonical records or demo materials become reference data.
These are small, repeatedly studied procedural families, not mocap or unseen
motion coverage. Related clips retain their existing train family assignment.

`target/learning/g1-full-body-reference/manifest.json` pins the model, MuJoCo
version, compiled scene, dimensions, joints, bodies, conventions and per-clip
SHA-256. Its nine compressed NPZ clips contain:

- T+1 full states, body positions/rotations/quaternions and body velocities;
- T+1 integration snapshots, including solver warm start, for reproducible resets;
- T original applied controls and original programmed goals, kept separately;
- T source observations and T+1 timestamps/contact counts.

State is qpos36/qvel35, with world Z up and free-root quaternion wxyz.
`mjSTATE_INTEGRATION` snapshots are pinned-runtime reset artifacts, not actor
features or a portable hardware-state contract. Body velocities preserve
`mj_objectVelocity(mjOBJ_BODY, flg_local=0)` angular-then-linear semantics.

The goal contains 338 reference-only channels: joint positions29/velocities29,
root gravity3/height1/linear velocity3/angular velocity3, thirty body positions
in the reference root frame and thirty relative rotations as two columns each.
The root frame includes tilt. World XY translation and yaw are removed; global
reference trajectories remain available to scoring. This does not give the
actor access to its actual global pose or linear velocity.

At control i the first target is reference frame i+1, aligned with next state.
Preview supplies frames i+1 through i+10. Repeated end frames carry an explicit
invalid mask. Source controls, source observations/previous actions and solver
state do not enter the goal. Actor observations retain the actual 93-channel
proprioceptive contract. This representation requires a new goal encoder/action
mapping: the existing v2 balance actor cannot consume it unchanged.

## Actual Re-Tracking Results

Every clip is restored at 0, 10 and 20 seconds. Each trial runs its remaining
30, 20 or 10 seconds; these are correlated origins, not 27 independent motions.
Only the initial integration state is restored. Later states evolve in MuJoCo.

| Controller | Falls / trials | Simulated / requested time | Joint RMSE | Body-position RMSE |
| --- | ---: | ---: | ---: | ---: |
| Recorded source setpoints | 0 / 27 | 540 / 540 s | 0 rad | 0 m |
| Reference next joint positions | 27 / 27 | 31.90 / 540 s | 0.107836 rad | 0.286617 m |

Source-control replay has maximum absolute state-component error zero, including
nonzero origins. Root position and velocity errors are also zero. The trace-based
rotation-angle calculation has a roughly 4.5e-8-rad floating-point floor even
for identical matrices. The position baseline survives 1.18148 seconds on
average; pooled root-position error is 0.304663 m and root-angle error 0.400345 rad.
Errors include all executed steps through falls, without imputing post-fall time.

Original controls are a feasibility oracle, not a learned or deployable tracker.
The joint-position baseline is not the previous sustained v2 policy, whose
inputs and targets differ. These results establish that actual reference posture
and required servo control are distinct for this model. They motivate learning
a reference-conditioned control mapping rather than lowering the old programmed
joint-goal threshold and calling it a whole-body task.

## Common Quality Target And Remaining Comparison

The [local quality target](../examples/learning/g1-full-body-reference-quality.json)
is fixed after these feasibility baselines and before learned reference-tracker
development. All 27 cells must complete and individually meet joint RMSE
0.03 rad, body/root position RMSE 0.05 m and root-angle RMSE 0.1 rad. Missing or
duplicate cells cannot pass. This is training-reference coverage, not a release
or generalization gate. It uses the existing absolute fall definition; it does
not claim the paper's reference-relative termination/reward is reproduced.

`replay_reference(..., mode="policy", policy=callback)` now accepts actual
proprioception, the current planned full-body frame, its future preview and
validity mask, returning
29 physical setpoints. The common harness clips actuator bounds and scores
physical trajectories. `assess_tracking_quality` applies the independent quality
target. The scalar placeholder reward is exp(-mean body-position squared error /
0.3²), not the paper's complete weighted reward; matched training must explicitly
freeze its reward before either learning method runs.

The [reference initialization study](G1_REFERENCE_INITIALIZATION.md) now implements
that encoder and control initialization, with both failed and passing variants.
Next freeze
the matched training charter: actor/critic state including causal observer memory,
action semantics, reward/termination, noise, collection/update budgets and selection.
Old v2 success on programmed goals is not a full-body initializer result. If a
shared initializer already passes this target, report zero incremental updates
for both methods. Include shared teacher/reference/parent development costs
separately; do not infer a model-based speedup from supervision or infeasible
position-only controls.

## Reproduce And Verify

```sh
moon run --target native scripts/collect_g1_full_body_reference.mbtx /Users/kq/Workspace/moonrobo /Users/kq/Workspace/moonrobo/target/learning/g1-temporal-input-study/collection.json /Users/kq/Workspace/moonrobo/target/learning/g1-balance-teacher-long-fit /Users/kq/Workspace/moonrobo/target/learning/g1-full-body-reference-new
moon build cmd/motion_dataset --target native
moon run --target native scripts/report_g1_full_body_reference.mbtx /Users/kq/Workspace/moonrobo /Users/kq/Workspace/moonrobo/target/learning/g1-full-body-reference /Users/kq/Workspace/moonrobo/output/research/g1-full-body-reference-study.json
target/learning-venv/bin/python -m unittest discover -s providers/motion_learning -p 'test_*.py'
```

The [verified report](../output/research/g1-full-body-reference-study.json) retains
63 episodes / 42,095 actual transitions. Every source/replay episode passes the
native MotionDataset reader, including 338-channel full-body goals. Native code
independently recomputes joint RMSE from all transitions (maximum difference
6.94e-17 rad) and full-state reproduction error (exact match). New numerical tests
exercise nonzero-origin physical reproduction, world-yaw/XY invariance, preview
alignment/padding, the policy callback path and complete quality coverage.
All 53 numerical provider tests and five native motion-data tests pass.
`moon info` completes with no errors and no new public MoonBit API; existing
toolchain warnings remain. Both new MoonBit scripts are formatted and checked.
Native quality assessment passes the source-control oracle and rejects every
joint-position trial; it does not qualify a learned reference tracker.

Collection takes 3.31 seconds, replay 6.19 seconds; the numerical provider's
25.99 seconds include serialization. Native validation, setup and prior teacher
development are excluded. No training update or efficiency comparison occurs.
The source snapshot used for this completed experiment is retained with its
hashes; current provider code additionally exposes the policy/quality helpers.
The subsequent [reference platform integration](G1_REFERENCE_PLATFORM.md) now
seals these clips and the failed/passing reference policies as learning-experiment
payloads, with origin-aware reference/physics inspection in the actual cockpit.
A standalone searchable motion library and full 3D/model overlays remain open.
Existing registered experiments remain intact. No physical authority changes.
