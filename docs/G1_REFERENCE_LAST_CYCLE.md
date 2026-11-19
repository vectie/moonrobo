# Last-Cycle Model And Physics Alignment

Updated: 2026-10-23. Status: six saved actor pairs compared; all 36 paired
physical archives independently verified. No new policy is trained or adopted.

The [initial-anchor study](G1_REFERENCE_REPLAY_ANCHOR.md) obtains three complete
thirty-second pose passes in one seed, while stand and joint-sine conditions
still fall. Its old-policy model MSE does not consistently predict survival.
Before extending training again, this diagnostic checks what the **last saved
twelve-update policy change** actually does in the model and simulator.

## Frozen comparison

The [charter](../examples/learning/g1-reference-last-cycle.json) pins the complete
source study at SHA-256
`a8308c60c8c1d9eb3e561eb667daac8736d7374989dd21e69182ebd0bd65ae25`.
Both FIFO and initial-anchor arms, all three training seeds and the representative
normal-friction stand, pose-offset and high joint-sine references are included.
Each trial starts at reference origin zero and requests the full thirty seconds.

For each run, the cycle-6 world model stays frozen. Its before/after policies
are the actual saved cycle-5 and cycle-6 actors, not new perturbations or a
selected intermediate checkpoint. The eighteen cycle-6 trials are reused from
the original final evaluations; eighteen missing cycle-5 trials are new CPU
MuJoCo collection. Each pair starts with exactly equal archived float32 state,
policy history and actual/reference observer features. Full solver state comes
from the unchanged reference snapshot through the existing physical harness.

Three complementary measurements are kept separate:

- Closed-loop H32 imagined returns for both policies from the identical restored
  origin, compared with actual discounted reward over the same first 32 physical
  steps (0.64 s), and separately over the actual full episode through fall/end.
- H8/H32 open-loop state prediction under each actor's recorded applied controls.
  Windows stay within one episode, overlap at half-horizon intervals and include
  the last complete pre-fall window. Short episodes without a full window report
  no score. Physical controls in these diagnostics are not imagined controls.
- H32 imagined returns at 256 fixed uniformly sampled transitions from each run's
  actual cycle-6 training collection. Causal history, EMA, phase and remaining
  duration are restored. This checks the sampled training-state objective; it
  does not supply physical counterfactual returns from those states or reproduce
  the exact optimizer minibatches.

There is no new fitting, optimization, amplitude search, checkpoint selection,
motion coverage, full-suite qualification or physical execution authority.
These are known development references; repeated final-suite diagnosis does
not constitute an untouched generalization test.

## Results

Changes below are cycle 6 minus cycle 5, averaged over the three representative
reference starts. Returns use the existing reward, gamma 0.99, and count the
terminal reward once. Full return is discounted through the actual episode,
so its horizon differs from the H32 predictor. These three-condition means are
not the original 27-cell suite statistics.

| Replay | Seed | Predicted H32 change | Actual H32 change | Actual full change | Survival before → after, s | H32 sign agreement /3 |
| --- | --- | --- | --- | --- | --- | --- |
| FIFO | 0 | +0.07639 | −0.22187 | +1.68713 | 4.293 → 16.673 | 1 |
| FIFO | 1 | +0.08487 | +0.03496 | +0.60527 | 16.153 → 12.773 | 2 |
| FIFO | 2 | −0.15925 | −0.06996 | −1.35766 | 10.547 → 5.180 | 3 |
| Initial anchor | 0 | +0.07067 | +0.03884 | +0.15197 | 8.993 → 15.187 | 2 |
| Initial anchor | 1 | −0.02415 | +0.03327 | +0.31651 | 10.600 → 15.147 | 0 |
| Initial anchor | 2 | +0.41179 | −0.06150 | +0.87638 | 4.387 → 21.293 | 0 |

The predicted H32 change has the same sign as actual H32 change in **8/18**
conditions. Its sign matches actual full-return change in **13/18**, a comparison
of different horizons rather than a calibrated long-term prediction. Anchor seed
1's short-term prediction gets all three signs wrong despite actual gains;
anchor seed 2 predicts three gains while actual H32 returns all decline, yet its
stand/sine full returns improve. FIFO seed 0 similarly loses early reward while
gaining full return in all three conditions. Neither early reward nor survival
alone captures the complete tracking target.

On the fixed cycle-6 training-state samples, imagined return improves in five
of six runs. FIFO seed 2 declines by 0.06559 even on that sample; the other
changes are +0.15652/+0.15636 for FIFO and +0.05483/+0.04197/+0.22800 for anchor.
This finite-update diagnostic does not establish whether that particular
decline comes from optimizer moments, minibatch variation or another cause.

These results establish model/physics disagreement for actual finite saved
updates, **not** a measured simulator Jacobian error, a proof that retention is
harmful, or a guarantee that another prediction loss will fix control. The next
useful controlled check is local physical action-response agreement at fixed
restored states, before changing model fitting or extending the actor budget.
Larger motion sources and an independent unseen-motion split remain necessary
parts of the full plan; this diagnostic does not replace them.

## Evidence and verification

The [verified report](../output/research/g1-reference-last-cycle.json) contains
36 episodes / **21,184 transitions**: 18 new / **8,246** and 18 reused / 12,938.
Independent reloads check source/actor/model hashes, causal features, actor
means, applied controls, reward/termination and reconstructed quality. Every
physical archive passes the native MotionDataset reader; MoonBit independently
recomputes discounted prefix/full returns from streamed rewards. Maximum feature
error is 1.37e-6, actor mean error 2.98e-7, applied-control error 0.00001371 rad
and quality reconstruction difference 3.26e-9. Reward reconstruction is exact.

The raw report SHA-256 is
`3dfd575b497e9def98807c0a4543a3c8baaea5725a2f133b93dc452435466405`.
The numerical provider takes 33.89 s of local CPU wall time, including setup,
model diagnostics and the new physics, excluding native verification. There is
no cost-to-target or GPU-hours claim. Three focused numerical tests pass for
episode window boundaries, terminal reward accounting and unequal-batch metric
weighting. No public MoonBit API or existing platform record is changed.
All five native motion-learning tests pass.
`moon info` and scoped script formatting complete; existing toolchain warnings
remain. The whole SuperMimic plan remains in progress.

## Reproduce

Use a fresh output study directory and the existing frozen source artifacts:

```sh
moon run --target native scripts/probe_g1_reference_last_cycle.mbtx /Users/kq/Workspace/moonrobo /Users/kq/Workspace/moonrobo/target/learning/g1-reference-replay-anchor /Users/kq/Workspace/moonrobo/target/learning/g1-reference-last-cycle
moon run --target native scripts/report_g1_reference_last_cycle.mbtx /Users/kq/Workspace/moonrobo /Users/kq/Workspace/moonrobo/target/learning/g1-reference-last-cycle /Users/kq/Workspace/moonrobo/output/research/g1-reference-last-cycle.json
target/learning-venv/bin/python -m unittest discover -s providers/motion_learning -p test_reference_last_cycle.py
```

This diagnostic is a local research artifact. The registered
[replay comparison](G1_REFERENCE_REPLAY_PLATFORM.md) and complete
[phase plan](SUPERMIMIC_PHASE_PLAN.md) retain their existing scope and status.

The subsequent [physical action-response study](G1_REFERENCE_ACTION_RESPONSE.md)
now measures first-control gradients with later controls fixed at 36 states.
H8 positive directions improve physical return in 36/36 states at both fixed
amplitudes; H32 improves 27/36 and 32/36. This narrows the next investigation
to complete action sequences and feedback, without resolving the full-policy
quality failure or claiming every world-model gradient is inaccurate.
