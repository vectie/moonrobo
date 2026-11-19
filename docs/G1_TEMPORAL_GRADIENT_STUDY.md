# G1 Dynamic-State Policy Direction Diagnostics

Updated: 2026-10-23. This follows the [temporal-input study](G1_TEMPORAL_INPUT_STUDY.md).
It tests the actual selected parameter changes and a fresh on-policy Adam
direction in restored MuJoCo physics. Five nonzero selected changes all improve
the learned-model objective, while four reduce mean remaining-episode physical
return on the new training origins. Dynamic-state prediction error is also
substantially higher than the standing control. This identifies a concrete
model/data and finite-update problem; it does not establish that every local
model derivative is wrong or that temporal conditioning is ineffective.

## What Is Paired

Both `frame` (H1/F0) and `preview` (H10/F10) use all three incoming supervised
actors and their previously selected model-refined checkpoints. The fixed
world-model is sustained fit seed zero, identical to the preceding study.
Checkpoint hashes bind the incoming actor, selected actor, model and original
model-training input. No weights, normalizations or deployment state change.

The probe uses only training-family cases: stand at friction 1.0 and independent
joint sinusoids at friction 1.0/0.8/0.6. Reset seeds are 4500/4501. Planned
snapshots occur at control steps 0/100/250. Frame actors reach 18/18/21 origins
out of 24 requested per seed; preview reaches 18/18/18. The 33 missing origins
follow earlier falls and remain explicit rather than becoming synthetic states.
There are 111 captured origins from 48 original physical episodes. Origins
within each episode overlap and are correlated, not independent trials.

Each origin saves MuJoCo's full integration state, the actor's causal history,
previous applied action, reference nominal pose, sine schedule and absolute
reference phase. Restored branches retain all of them. Initial and restored
baseline trajectories have exactly zero maximum state/action error over the
local window, and identical remaining episode lengths. This includes the
history-dependent preview policy; it is not a reset with an empty memory.

Two parameter directions are compared:

- `on_policy_adam`: one fresh Adam ascent step, learning rate 0.0001, fitted
  on that actor's captured training-origin batch through the H32 world model.
- `selected_refinement`: the full parameter difference between the actual
  incoming and previously selected model-refined checkpoints. Frame seed zero
  retained update zero, so its direction is explicitly zero.

Multipliers are −0.1/0/0.1/1. They scale a saved parameter delta, not action
radians or a complete physical gradient. Zero branches reuse the verified
baseline. World-model evaluation rolls the history and reference forward;
physical branches do the same using actual next observations. Model weights
remain unchanged and receive no parameter gradients.

Both returns use the same tracking/balance/height/action-smoothness reward,
discount 0.99 and soft continuation weights, without critic bootstrap. The
physical branch additionally stops on the declared actual fall. The local
return stops after 32 steps or an earlier fall. The full return stops at a fall
or the original ten-second episode boundary: a snapshot at five seconds has
at most five seconds remaining, not a new ten-second episode. Return values
are reward units, distinct from survival seconds and physical qualification.

## Selected Changes In Actual Physics

All rows below use multiplier one on the same origins within that row:

| Variant / seed | Origins | Model H32 Δ | Physics H32 Δ | Physics remaining Δ | Mean remaining steps Δ |
| --- | ---: | ---: | ---: | ---: | ---: |
| Frame / 0 | 18 | 0 | 0 | 0 | 0 |
| Frame / 1 | 18 | +1.6663 | −0.1854 | −6.3812 | +13.17 |
| Frame / 2 | 21 | +0.6599 | +0.0160 | +4.1709 | +31.14 |
| Preview / 0 | 18 | +1.6993 | −1.6536 | −11.0332 | −10.50 |
| Preview / 1 | 18 | +8.8596 | −1.8467 | −5.7925 | +16.83 |
| Preview / 2 | 18 | +3.5291 | −3.1779 | −9.1788 | −28.56 |

The earlier canonical improvement therefore does not transfer uniformly to
the independently sampled dynamic training states. More survival steps can
coexist with worse discounted tracking/balance return. Preview seed one reduces
falls from 18 to 14 among these correlated origin branches but still reduces
mean full return. Neither a single return statistic nor a fall count alone
describes all effects.

Fresh one-step Adam directions improve mean model H32 return for all six
actors. Five improve mean physical H32 return at multiplier one, but only two
improve mean remaining-episode return. The changes are:

| Variant / seed | Model H32 Δ | Physics H32 Δ | Physics remaining Δ |
| --- | ---: | ---: | ---: |
| Frame / 0 | +0.1620 | +0.0020 | +4.1270 |
| Frame / 1 | +0.3049 | +0.0036 | −0.6568 |
| Frame / 2 | +0.2636 | +0.0019 | −0.2087 |
| Preview / 0 | +0.5357 | −0.0607 | −0.0370 |
| Preview / 1 | +1.3010 | +0.0278 | −1.4735 |
| Preview / 2 | +0.6847 | +0.0099 | +2.6689 |

Thus even on-policy, short-horizon improvement does not reliably imply a
longer physical improvement. This remains true with bootstrap already disabled;
it cannot be attributed only to a bad terminal critic.

## Smaller Steps And Open-Loop Prediction

The report also retains centered differences `(J(+0.1)−J(−0.1))/0.2`.
For the selected frame seed-one direction, mean model/local/full slopes are
+0.6766/+0.1276/+21.3657, although the complete selected update reduces both
physical returns. A small perturbation and the full selected displacement can
have opposite effects. For selected preview seeds zero and two, local physical
slopes already oppose the model, while the full physical slopes are positive
at this smaller scale. These nonlinear, contact-dependent results do not justify
treating the multiplier-one changes as exact derivatives. The report retains
every origin's slope and separate local/full sign denominators; near-flat pairs
are excluded from sign agreement counts.

Independently of policy-gradient tests, the same model predicts forward under
the **actual recorded baseline controls**. Normalized state MSE uses the same
frozen state scale throughout and excludes absolute root X/Y. It is an error
at the named prediction endpoint, not the average of earlier endpoints:

| Variant / seed | Stand H32 MSE / windows | Dynamic H32 MSE / windows | Dynamic root height MAE (m) |
| --- | ---: | ---: | ---: |
| Frame / 0 | 0.06714 / 6 | 0.93263 / 12 | 0.06614 |
| Frame / 1 | 0.06250 / 6 | 0.74141 / 12 | 0.04529 |
| Frame / 2 | 0.05774 / 6 | 0.41218 / 15 | 0.02598 |
| Preview / 0 | 0.05825 / 6 | 0.92401 / 12 | 0.08166 |
| Preview / 1 | 0.05850 / 6 | 1.09235 / 7 | 0.03105 |
| Preview / 2 | 0.05954 / 6 | 0.76076 / 9 | 0.03422 |

Only actual complete prefixes contribute to each endpoint. In particular,
preview seed-one/two dynamic H32 scores have 7/9 windows rather than the 12
origins available at one step; early falls do not receive fabricated targets.
One- and eight-step scores are also retained. Dynamic error already exceeds
standing at one step, so this is not solely a long-rollout accumulation issue.
Different physical states/actions and sparse surviving prefixes limit causal
interpretation; these scores are neither a new held-out motion benchmark nor
proof of derivative correctness.

## Evidence, Reproduction And Next Action

The [verified report](../output/research/g1-temporal-probe.json) includes both
summaries, bindings, every centered slope, complete aggregate subsets and
per-motion prediction scores. Raw simulator origins, branch returns and saved
parameter directions remain in `target/learning/g1-temporal-probe`. These are
diagnostics, not newly selected policies or registered training successes.

```sh
moon run scripts/probe_g1_temporal_inputs.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-temporal-input-study /absolute/path/to/moonrobo/target/learning/g1-temporal-refinement /absolute/path/to/moonrobo/target/learning/g1-sustained-model-study/new-fit /absolute/path/to/moonrobo/target/learning/g1-temporal-probe
moon run --target native scripts/score_g1_temporal_probe.mbtx /absolute/path/to/moonrobo/target/learning/g1-temporal-probe /absolute/path/to/moonrobo/target/learning/g1-temporal-input-study /absolute/path/to/moonrobo/target/learning/g1-temporal-refinement /absolute/path/to/moonrobo/output/research/g1-temporal-probe.json
```

Use a fresh probe output directory. Sources, config and experiment are archived
before workers launch. All 31 numerical tests pass. The two new regressions
exercise restoring a nonzero, history-dependent actor during a changing
reference, previous-action memory, original episode end, rejection of test
origins, per-origin imagined returns and finite Adam ascent. All ten relevant
MoonBit data/registry tests pass. No public MoonBit API changes are introduced;
the prior full native suite passed all 887 tests in the preceding slice.

The subsequent [dynamic refit](G1_DYNAMIC_REFIT_STUDY.md) consumes all 1332 new
temporal teacher/student episodes through native-validated actual-action streams.
Frozen-normalization, equal-budget old-only and mixed-data controls both improve
canonical prediction. Mixed replay improves dynamic H32 prediction for all three
sampling seeds but does not consistently improve remaining physical return.
The current temporal policy still lacks a calibrated temporal value model;
testing that longer-return estimate is the next bounded SM-3 comparison.
Smaller displacement and full-physics scoring remain relevant because small/full
updates can disagree even with an improved model. Stable all-case learned control
and the overall SM phase gates remain unfinished; no hardware operation or
general hardening is part of this slice.
