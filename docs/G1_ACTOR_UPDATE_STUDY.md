# G1 Actor-Parameter Direction And Step-Size Study

Updated: 2026-10-23. This follows [physical critic calibration](G1_PHYSICS_CRITIC.md).
It probes actual Adam parameter updates in restored closed-loop MuJoCo, then
compares two actor learning rates with early physical checkpoint selection.
No candidate reaches the existing ten-second control gate.

## Parameter Directions In The Same Physics States

The [probe](../providers/motion_learning/actor_update_probe.py) uses the three
selected physical-critic actors and their calibrated critics, with the same
frozen augmented-data world model. Only constant-goal training families are
used: six standing/pose cases at three friction values, reset seeds 930/931,
and origins at 0/0.5/1.0/1.5 seconds. All 144 requested origins exist: 48 per
policy from 12 parent episodes each. These correlated origins are not 144
independent reset trials.

Two equally sized batches generate directions for each policy: 48 seeded
uniform replay windows, or the 48 recent physical origins. Each direction is
one fresh Adam step with learning rate 0.0003, the training loss sign/divisor
and gradient clipping. It uses the optimizer recipe, not the exact random
minibatch or optimizer history of an earlier recorded training update.

Multipliers -1/0/0.01/0.1/1 apply the saved parameter delta while preserving
actor buffers. The model and critic remain fixed. Every physical evaluation
restores full MuJoCo integration state, preceding action, goal and its original
friction, then runs the changed actor closed-loop for up to 32 steps. Unchanged
actors reproduce recorded parent states/actions exactly: maximum error zero.
Actual falls stop the physical rollout and remove the tail without padding.

The probe reports actual window reward separately from its critic-bootstrapped
return. The latter uses the same critic on the final physical state; it is still
an estimated continuation value, not a complete physical Monte Carlo return.
Model predictions below use those same recent origins, even when the direction
was fitted on replay states.

Full-size parameter step:

| Direction batch / seed | Predicted objective change | Actual 32-step reward change | Actual window + critic-tail change |
| --- | ---: | ---: | ---: |
| Replay / 0 | +4.1853 | +0.3125 | +0.8232 |
| Replay / 1 | +5.8323 | +0.3394 | -0.2492 |
| Replay / 2 | +3.8525 | +0.2354 | +0.5426 |
| Recent / 0 | +10.0770 | -0.5280 | +3.5139 |
| Recent / 1 | +7.0343 | +0.3750 | -0.0967 |
| Recent / 2 | +5.1912 | -0.0755 | +0.1555 |

Replay directions improve actual window reward on average for all three seeds,
but not every state's bootstrapped score. Recent-state directions do not have
a consistent advantage: two lower actual window reward while increasing the
estimated tail contribution. This is not enough to justify switching the actor
sampler or claiming a universally incorrect update direction.

At one-tenth replay-step size, mean physical bootstrapped changes are positive
for all three seeds (0.0730/0.0238/0.2527), but only 52.1%/39.6%/60.4% of origins
improve. At one-hundredth size, seed zero's mean bootstrapped change is negative.
The response is not monotonic across scales. The [complete summary](../output/research/g1-actor-update-probe-summary.json)
retains all multipliers, signs, counts and checkpoint/model bindings. Raw
integration origins, per-origin outcomes and parameter deltas stay in the run.

```sh
moon run --target native scripts/probe_g1_actor_update.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-counterfactual-study/augmented /absolute/path/to/moonrobo/target/learning/g1-physics-critic-study/critic-physics/policy /absolute/path/to/moonrobo/target/learning/g1-actor-update-probe
```

## Learning-Rate Comparison And Earlier Checkpoints

The next frozen charter retains replay sampling and physical critic targets.
Both methods start from the same calibrated selected checkpoints, use the
same model/data/reward/action range, and run 200 actor updates, batch 64 and
32-step imagination. Critics have 1600 optimizer steps, refreshed every 20
actor updates from six training-only physical cases. Collection seed base is
1200 in both methods, distinct from the prior study.

Only actor learning rate differs: 0.0003 for `actor-lr-standard`, 0.00003 for
`actor-lr-small`. Both now evaluate validation seeds 30–32 at updates
0/1/5/10/20/50/100/150/200. Extra early checkpoints are explicitly configured;
existing configurations retain their previous schedule. Final seeds 8000–8002
are never used for weight selection. The gate remains zero falls in all nine
ten-second-maximum trials and mean joint RMSE ≤0.15 rad.

| Method / seed | Selected update | Incoming → selected survival (s) | Incoming → selected RMSE (rad) | Falls / trials |
| --- | ---: | --- | --- | ---: |
| Standard / 0 | 5 | 1.9644 → 2.2733 | 0.14251 → 0.15072 | 9 / 9 |
| Small / 0 | 50 | 1.9644 → 2.1756 | 0.14251 → 0.15217 | 9 / 9 |
| Both / 1 | 0 | 2.2578 → 2.2578 | 0.09357 → 0.09357 | 9 / 9 |
| Both / 2 | 0 | 1.9311 → 1.9311 | 0.16286 → 0.16286 | 9 / 9 |

The standard-step early candidate survives longer than its incoming policy,
with worse tracking and RMSE above the gate. A smaller step is not better in
this protocol. Early evaluation reveals an update the old 50-step schedule
would not directly inspect; it does not make the later training stable. No
selected candidate qualifies. Repeated incoming actors are not independent
new controllers. Independent re-scoring confirms unchanged actors' trajectories
exactly match their incoming counterparts under the same final conditions.

The [study report](../output/research/g1-actor-step-study.json) retains initial,
selected and complete validation outcomes for each seed, plus physical-training
payload references. Latest weights and rejected trials remain available.

```sh
moon run --target native scripts/fit_g1_physics_critic.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-counterfactual-study/augmented /absolute/path/to/moonrobo/target/learning/g1-physics-critic-study/critic-physics/policy /absolute/path/to/moonrobo/target/learning/g1-actor-step-study --small-step
moon run --target native scripts/score_g1_actor_steps.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-actor-step-study /absolute/path/to/moonrobo/target/learning/g1-physics-critic-study/critic-physics/policy /absolute/path/to/moonrobo/target/learning/experiment-book/moondata /absolute/path/to/moonrobo/output/research/g1-actor-step-study.json
```

## Evidence And Next Experiment

Both methods are registered in MoonData under the IDs above with all three
selected/latest policies, original physical traces, shared world-model/data
artifacts and compressed physical critic training records. Gzip integrity and
producer/MoonData checksums match, complete root validation has zero findings,
and physical execution authority stays false. No new job service or UI flow
is introduced.

Seventeen numerical tests pass, including the optimizer direction sign, reversed
and zero parameter steps, buffer preservation and prior physics/return tests.
Real G1 restored-trajectory checks, all actor reload checks, frozen-model checks
and the nine declared checkpoint times are verified by the executed workflows.
MoonBit interfaces remain unchanged; script checks and scoped formatting pass.
`moon info` completes with zero errors; existing toolchain warnings remain.
The old `g1-long-dynamics/train-batch.json` is losslessly archived as
`train-batch.json.gz` to free local disk space. Its source dataset, reports and
weights remain intact; the active augmented batch stays uncompressed. Run
`gzip -d` on an old archive before passing it to a workflow expecting JSON.

The [short-cycle study](G1_SHORT_CYCLE_STUDY.md) now tests shorter actor-update
segments with physical recollection and world-model fitting between segments.
One seed gains survival with worse tracking, and all candidates still fall.
The early improvement does not establish that a frozen model is the only failure cause.
Current window/tail probes are not full-duration physical-gradient proofs.
Stable control, broader motion learning, matched efficiency and full phase
acceptance remain open. Production hardening stays deferred.
