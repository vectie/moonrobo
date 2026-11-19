# G1 Reference Trajectory-State Training Duration

Updated: 2026-10-23. Status: six-cycle training and independent native verification
completed. Two seeds improve, one regresses; no complete policy qualifies.
The complete [phase plan](SUPERMIMIC_PHASE_PLAN.md) remains active.

The [actor-state origin comparison](G1_REFERENCE_STATE_ORIGINS.md) improves all
three paired seed means after three cycles but passes no full-policy gate.
This experiment asks whether the same recipe sustains that progress through
three additional collection/model/actor cycles. It is a training-duration
comparison, with deliberately different total budgets.

## Frozen comparison

The [charter](../examples/learning/g1-reference-extended-training.json) fixes
three seeds, six total cycles and the original final 27-cell quality suite
before running. `replay-prefix` is the existing three-cycle trajectory-state
baseline; `replay-prefix-extended` has six cycles and 72 actor steps, versus 36.
There is no new initialization, supervised labeling, reward, optimizer setting,
actor-origin distribution, local step cap, selection audit or quality threshold.
Each cycle still collects 27 episodes across nine clips and 0/10/20-second origins,
fits 900 model and 128 physical-return value updates, and performs 12 H32 no-tail
actor updates from uniform current-cycle pre-action states.

Every final policy must complete all 27 remaining 30/20/10-second trials with
zero falls, joint RMSE ≤0.03 rad, body/root position RMSE ≤0.05 m and root angle
RMSE ≤0.1 rad. These are known training references. Final checkpoint means the
fixed sixth cycle; no intermediate quality-based stopping or seed selection
is introduced. Completed trials with excessive tracking errors still fail.

## Reconstruct, then continue

The original three-cycle report is pinned at SHA-256
`c9713dd0cdc6118d83c598a05120fbda15f7e29e946c57387704217d34c95387`.
Its original actor/model/value optimizer snapshots were not saved. Instead of
resetting Adam at the third-cycle weights or recollecting its physics, the
worker rebuilds learning from the original zero-output actor and shared data.
It restores each first-three-cycle numeric batch, repeats the original seeded
model/value/actor fitting operations and checks all three sets of weight tensors
against their original checkpoint after each cycle. Only then does the same
live optimizer/replay/RNG state proceed into cycle 4.

This reconstructs optimizer moments through the original operations; there is
no original optimizer snapshot against which to independently compare those
moments. It is a bounded scientific reconstruction, not a complete job-resume
product or evidence that every possible interruption can resume exactly.
Independent verification reloads both old and reconstructed cycle weights and
compares their tensors and reported hashes again.

The paired corpus retains 360 inherited records: 27 incoming evaluations,
81 common first collections, 9 model diagnostics, 162 later trajectory-state
collections and 81 baseline final trials. Only 243 cycle 4–6 collections and 81
new final trials are collected: 324 new, 684 paired. The preceding reset-only
arm's unrelated physics is not recounted. Original files retain their bytes
and are referenced in place.

New provider wall time on this local CPU includes the reconstruction fits;
it is measured elapsed time, not summed CPU core-seconds. Standalone
six-cycle accounting also preserves the old collection costs. Reconstruction,
fresh fitting/collection and final evaluation are reported separately. A
successful matched-cost or GPU speedup cannot follow from this larger-budget
comparison.

## Results and verification

All three fixed final suites have finished. No actor is selected or promoted.

| Seed | Cycles | Falls /27 | Mean survival s | Individual passes /27 | Pooled joint RMSE rad | Body RMSE m | Root position RMSE m | Root angle RMSE rad |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | 3, reused | 27 | 6.698 | 0 | 0.03949 | 0.12681 | 0.13130 | 0.19175 |
| 0 | 6 | 18 | 12.004 | 0 | 0.03384 | 0.08008 | 0.07912 | 0.19767 |
| 1 | 3, reused | 27 | 5.546 | 0 | 0.03432 | 0.13462 | 0.13749 | 0.21274 |
| 1 | 6 | 22 | 10.219 | 5 | 0.02452 | 0.09502 | 0.09892 | 0.14348 |
| 2 | 3, reused | 24 | 7.319 | 2 | 0.03643 | 0.11497 | 0.12067 | 0.17930 |
| 2 | 6 | 27 | 4.930 | 0 | 0.05748 | 0.17250 | 0.18182 | 0.22622 |

Seeds 0 and 1 improve survival and reduce falls, but seed 2 regresses and loses
its two previous individually qualified cells. Seed 0 completes nine trials
without passing their tracking limits; its pooled root angle error also
increases. Seed 1 completes five and passes their individual limits, but still
falls in its other 22 conditions. No full-policy target is reached. The mean
and pooled scores use observed pre-fall trajectories, while qualification
continues to require each full reference remainder and every metric.

The five seed-1 passes consist of the following known pose conditions; none
starts at 0 s or constitutes a qualified full-thirty-second reference:

| Condition | Reference origin s | Completed remainder s | Joint RMSE rad | Body RMSE m | Root position RMSE m | Root angle RMSE rad |
| --- | --- | --- | --- | --- | --- | --- |
| pose-offset | 10 | 20 | 0.01234 | 0.02587 | 0.02645 | 0.04373 |
| pose-offset | 20 | 10 | 0.01240 | 0.02207 | 0.02284 | 0.03525 |
| pose-offset-medium-friction | 10 | 20 | 0.01232 | 0.02548 | 0.02623 | 0.03980 |
| pose-offset-medium-friction | 20 | 10 | 0.01234 | 0.02182 | 0.02276 | 0.03158 |
| pose-offset-low-friction | 20 | 10 | 0.01235 | 0.02178 | 0.02279 | 0.03033 |

Seed 0 completes all nine pose conditions, including three full 30 s trials,
but none passes the tracking target. Its standard-friction full 30 s trial has
joint RMSE 0.04161 rad and root angle RMSE 0.34246 rad, both beyond their limits,
despite root position RMSE 0.01900 m. Survival and a small position error alone
therefore do not establish accurate reference tracking.

The noisy training collections preceding cycles 4/5/6 have mean durations
5.277/5.021/5.882 s in seed 0, 4.748/5.184/8.950 s in seed 1 and
5.391/4.673/4.881 s in seed 2. These are noisy own-policy training episodes
before their corresponding updates, not additional noiseless quality checks.
The experiment does not isolate model error, exploration noise, changing
state coverage or accumulated policy drift as the cause of regression.

For seed 2, the same held-out initial-policy diagnostic has normalized H32 MSE
0.05821 after cycle 3, 0.10007 after cycle 5 and 0.09114 after cycle 6. Its local
logit step cap never activates, so a missing cap is not the implementation
explanation. These fixed diagnostics are not the complete final-policy state
distribution. The model retains only the latest 20,000 fitting windows; sustained
collection replaces older data. This makes replay composition/model forgetting
a concrete next controlled hypothesis, not a demonstrated cause. Test physical
update directions and a retained older-data component before extending budgets
again; keep fitting budgets and the quality target fixed within that comparison.

New provider elapsed time on the local CPU is 490.22 s, excluding independent
verification and inherited physical collection. No cost-to-target is reached.
This supports further controlled investigation of sustained updates rather
than another budget extension justified by only the best seed. The charter,
all six final policies, cycle weights and failed outcomes remain preserved.

## Independent verification

The [verified report](../output/research/g1-reference-extended-training.json)
contains 684 episodes /200,394 transitions, including 324 new /104,169 and 360
inherited /96,225. All pass reconstruction of causal features, sampled actions,
shared rewards/termination and native MotionDataset reading. Source/behavior
hashes, unchanged baseline results and complete final coverage are checked.
Maximum feature error is 1.43e-6; control reconstruction error is 0.00001681 rad;
reward reconstruction is exact and original quality scalars differ by at most
4.49e-9 when rebuilt from float32 archives.

All nine reconstructed cycle checkpoints independently match their original
actor/model/value tensors. Uniform origin RNG draws are independently rebuilt
for both three- and six-cycle runs. The new cycles sample 6,912 origins; seed 1's
last cycle reaches 29.78 s after reset (mean 6.08 s), while seed 2 remains much
earlier (last-cycle mean 2.64 s). This is an observed coverage difference, not
evidence isolating why their learning differs.

The final six-cycle actor is paired with the actual cycle 6 dynamics/value
artifacts for its float64 directional check at a recorded one-second state.
Absolute finite-difference error is 1.52e-9 with unchanged frozen model/value
tensors and no critic tail. The retained three-cycle baseline's check passes
too. These verify autodiff implementation consistency, not simulator Jacobians.

The [compact comparison](../output/research/g1-reference-extended-training-summary.json)
retains completed cells, per-cycle noisy collection/model errors, local step
sizes, sampling, reconstruction hashes and measured cost components. Sixteen
reference numerical tests and five native MotionDataset tests pass; the changed
MoonBit scripts check and format. `moon info` has no errors or new public API
change; existing toolchain warnings remain.

The complete three-versus-six-cycle comparison remains a research artifact.
Its six-cycle FIFO arm is subsequently included in the registered
[FIFO/initial-anchor comparison](G1_REFERENCE_REPLAY_PLATFORM.md). This does not
register a separate full duration-comparison entry or replace the original
three-cycle results.

## Reproduce

The existing study, reference assets and numerical environment are required.
The output study directory must be new; config and source are frozen before
launching the worker.

```sh
moon run --target native scripts/fit_g1_reference_learning.mbtx /Users/kq/Workspace/moonrobo /Users/kq/Workspace/moonrobo/target/learning/g1-full-body-reference /Users/kq/Workspace/moonrobo/target/learning/g1-reference-state-origin/initial/actor-zero-output.pt /Users/kq/Workspace/moonrobo/target/learning/g1-reference-extended-training /Users/kq/Workspace/moonrobo/examples/learning/g1-reference-extended-training.json /Users/kq/Workspace/moonrobo/target/learning/g1-reference-state-origin
moon run --target native scripts/report_g1_reference_learning.mbtx /Users/kq/Workspace/moonrobo /Users/kq/Workspace/moonrobo/target/learning/g1-reference-extended-training /Users/kq/Workspace/moonrobo/output/research/g1-reference-extended-training.json
moon run --target native scripts/summarize_g1_reference_extension.mbtx /Users/kq/Workspace/moonrobo/output/research/g1-reference-extended-training.json /Users/kq/Workspace/moonrobo/output/research/g1-reference-extended-training-summary.json
```

This study does not change the default policy or physical execution authority.
Sustained reference control, larger motion coverage, the full workbench,
successful matched model/PPO efficiency and E1/hardware qualification remain
separate requirements.

The subsequent [initial-anchor replay comparison](G1_REFERENCE_REPLAY_ANCHOR.md)
now tests that retention hypothesis at the same six-cycle episode/update budget.
Three known pose trials complete and qualify for 30 s in seed 1, whose individual
passes rise from 5 to 9. Seed 0 gains three individual passes but has more falls;
seed 2 recovers survival to 16.614 s without qualifying any of its sixteen
completions. Its old-policy H32 diagnostic worsens despite that recovery.
All 927 paired records validate. Replay matters, but neither more survival nor
one diagnostic prediction score establishes full-policy qualification.
