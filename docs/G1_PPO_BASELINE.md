# G1 PPO Baseline And Shared Physics Comparison

Implemented: 2026-10-23. This adds actual simulator-trained PPO to SM-2.2 and a
first final-quality comparison to SM-3.4. PPO and the model-based warm-start
actors all still fail the two-second no-fall criterion. No learning-speed or
hardware qualification claim follows from these results.

The later [temporal PPO study](G1_TEMPORAL_PPO_STUDY.md) uses supervised H10/F10
incoming actors, calibrated finite-task values and ten-second episodes. It
retains a different report format and objective/boundary semantics from this
original GAE baseline. Its candidates also fail qualification; the two runs'
sample counts and returns must not be merged as one training curve.

## Run

Use the pinned environment/model from [CPU physics setup](G1_CPU_PHYSICS.md)
and initial numeric training windows from [dynamics fitting](G1_DYNAMICS.md):

```sh
moon run --target native scripts/fit_g1_ppo.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-dynamics /absolute/path/to/moonrobo/target/learning/g1-ppo-new
moon run --target native scripts/score_g1_ppo.mbtx /absolute/path/to/moonrobo/target/learning/g1-ppo-new
moon run --target native scripts/compare_g1_learning.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-ppo-new /absolute/path/to/moonrobo/target/learning/g1-policy-warm-native /absolute/path/to/moonrobo/target/learning/g1-quality-new
```

The numerical provider is [`ppo.py`](../providers/motion_learning/ppo.py);
the fixed budget/configuration is
[`g1-ppo-fit.json`](../examples/learning/g1-ppo-fit.json). MoonBit scripts own
invocation, checks and derived reports. Large local results stay in `target/`.

## Algorithm And Comparison Bounds

PPO samples actions in MuJoCo and optimizes a clipped likelihood-ratio
surrogate with minibatch epochs. Its value estimator uses GAE. These are
independent implementations of the methods described in the
[PPO paper](https://arxiv.org/abs/1707.06347) and
[GAE paper](https://arxiv.org/abs/1506.02438).

The baseline shares the model-based actor: 93 proprioceptive observation
channels plus 29 target angles, two 128-wide SiLU hidden layers, and bounded
residual setpoints within ±0.08 rad of the target. Actuator ranges still clip
applied inputs. The privileged state/context critic has the same 128/64 hidden
widths and bounded value output. The actor cannot see privileged root position
or friction context. It starts with zero residual, without warm-start weights.

The sampled Gaussian is over pre-tanh latent actions, with fixed standard
deviation 0.5. PPO stores those exact latent samples and computes their
likelihood ratios before tanh/actuator clipping. Rewards use the same tracking,
uprightness, height and action-smoothness function as model-based learning,
evaluated on actual simulator next states. PPO does not use learned transition
predictions or imagined gradients. Physical falls remove value bootstrap;
time limits preserve bootstrap but stop GAE recurrence before the next reset.

Normalization uses only the initial training windows. That reuses logged data
statistics, not dynamics weights; its data collection/loading cost is excluded
from the reported optimization time. Overlapping windows weight those statistics
as in the existing model-based actor. This is not a claim of training without
offline inputs.

Training uses standing references at friction 1.0, 0.8 and 0.6. Each update
collects 12 complete episodes; validation uses waist sway and seeds 10–12,
every 20 updates. Selection ranks fewer falls, longer survival, then lower
tracking error. The frozen budget is three training seeds, 160 updates,
at most 160000 control transitions per seed, and 180 seconds checked at update
boundaries. A full update's worst-case transitions are reserved before collection.
The final evaluation uses seeds 100–102, newly chosen for this comparison,
with stand, sway and arm wave: nine two-second trials per candidate. It uses
no added action noise and the existing fall thresholds. All training and final
evaluation are on CPU; no GPU, purchase or physical dispatch is involved.

## Measured Results

Recorded PPO run: `target/learning/g1-ppo-baseline`. Each seed completed all
160 updates and 1920 training episodes; every training episode ended in a fall.
The three seeds used 123877/124371/125331 training transitions and
45.15/47.35/47.51 seconds respectively. Time includes collection, updates and
in-training validation, but excludes initial data loading, final scoring,
serialization and prior data creation. It is not total cost to a qualified skill.

The initial run retained 15 final trials per actor because the collection
configuration also included two extra standing-friction cases. Its original
reports/weights remain unchanged. `score_g1_ppo.mbtx` selects the nine declared
stand/sway/wave trials by case ID and records the source digest. Independently
re-scoring each PPO checkpoint on the canonical nine reproduces those metrics
within 1e-12. New runs explicitly separate collection and evaluation configurations,
so their final report contains the nine canonical trials directly.

`target/learning/g1-quality-comparison/report.json` records independent scoring
of all six saved policies with the same actual physics configuration and
evaluation seeds. The reference position controller falls in 9/9 trials,
survives 1.2444 seconds on average and has mean joint RMSE 0.0971 rad.

| Method | Training seed | Mean survival (s) | Mean joint RMSE (rad) | Falls / trials |
| --- | ---: | ---: | ---: | ---: |
| PPO | 0 | 1.3667 | 0.0902 | 9 / 9 |
| PPO | 1 | 1.4067 | 0.0956 | 9 / 9 |
| PPO | 2 | 1.4622 | 0.0965 | 9 / 9 |
| Model-based warm start | 0 | 1.4956 | 0.1152 | 9 / 9 |
| Model-based warm start | 1 | 1.4622 | 0.1200 | 9 / 9 |
| Model-based warm start | 2 | 1.4778 | 0.1203 | 9 / 9 |

The warm-start actors generally survive longer here but track less accurately.
Every candidate still falls. Training histories, normalization data, warm starts,
and simulation budgets differ, so this is final checkpoint quality on a shared
suite, not a matched sample-efficiency comparison or reproduction of the paper's
speedup. These evaluation conditions have now been inspected; future tuning
needs another declared evaluation set for fresh generalization claims.

## Standing Diagnostic And Verification

`baseline-diagnostic.json` preserves joint-specific errors from the original
position controller. The largest RMS errors are left/right ankle pitch,
approximately 0.350 rad. Each ankle's position-servo gain is 20, so the current
±0.08 rad residual changes its pre-saturation setpoint-force term by at most
1.6 N·m. This identifies a useful action-range/contact-control hypothesis;
it does not establish that actuator range alone causes the fall. The diagnostic
retains all joint errors and the actual final height/uprightness.

Four return tests pass, including terminal bootstrap removal and time-limit
bootstrap without cross-episode GAE leakage. Sharing actor/critic code required
a small refactoring: `verify_policy_refactor.mbtx` re-scored all three prior
warm-start actors and matched their baseline and candidate trajectories exactly
over 54 trials, excluding wall-clock time. Selected PPO checkpoint reloads
match inference exactly. `verify_g1_ppo.mbtx` exercises collection, optimization,
checkpointing and the explicitly separate nine-trial evaluator with a short run.
The 883 native repository tests also pass; `moon check` and `moon info` finish
with zero errors. New MoonBit scripts are formatted. Existing toolchain warnings
remain.

The initial run archives its executed numerical source files beside the results.
Its `ppo.py` SHA-256 matches `report.json`; current source additionally separates
collection/evaluation inputs. Checkpoints retain actor, critic, normalization,
body layout and configuration. Optimizer/RNG restoration is not implemented.

The action-range ablation below now supplies another control measurement.
Better coverage of upright/contact states, PPO artifact registration,
cost-to-target comparison, critic/horizon
ablations and a stable controller remain outstanding. General job recovery and
deployment work remain deferred.

## Action-Range Ablation Protocol

The follow-up fixes [`g1-ppo-wide-fit.json`](../examples/learning/g1-ppo-wide-fit.json)
before training. It changes the actor residual bound from ±0.08 to ±0.3 rad,
with the same three seeds, initial train-only normalization, architecture,
training cases, reward, optimizer and maximum step/time budgets. Selection still
uses validation seeds 10–12. Final scoring switches to seeds 200–202, shared by
the saved narrow and wide actors. Fixed latent standard deviation means the
physical exploration amplitude also increases; this does not isolate action
capacity from exploration effects.

```sh
moon run --target native scripts/fit_g1_ppo.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-dynamics /absolute/path/to/moonrobo/target/learning/g1-ppo-wide /absolute/path/to/moonrobo/examples/learning/g1-ppo-wide-fit.json
moon run --target native scripts/compare_g1_learning.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-ppo-baseline /absolute/path/to/moonrobo/target/learning/g1-ppo-wide /absolute/path/to/moonrobo/target/learning/g1-action-range-comparison action-range
```

New fit invocations archive the executed numerical source files before launch.
The comparison records actual steps, updates, elapsed training time and selection
for each checkpoint; equal maximum budgets do not mean equal collected samples.
Raw reports and final physics traces remain available for failed candidates.

Recorded wide run: `target/learning/g1-ppo-wide`. The three seeds selected
updates 100/140/80. Seeds 0 and 1 completed 160 updates; seed 2 stopped at 159
because another complete collection update would exceed the transition budget.
Actual training transitions were 156225/157169/158943 and elapsed training times
53.83/54.85/55.97 seconds. The same-script shared evaluation is stored under
`target/learning/g1-action-range-comparison`:

| Residual bound | Training seed | Mean survival (s) | Mean joint RMSE (rad) | Falls / trials |
| --- | ---: | ---: | ---: | ---: |
| ±0.08 rad | 0 | 1.3667 | 0.0902 | 9 / 9 |
| ±0.08 rad | 1 | 1.4067 | 0.0957 | 9 / 9 |
| ±0.08 rad | 2 | 1.4600 | 0.0962 | 9 / 9 |
| ±0.3 rad | 0 | 1.5089 | 0.0927 | 9 / 9 |
| ±0.3 rad | 1 | 1.6467 | 0.0868 | 9 / 9 |
| ±0.3 rad | 2 | 1.7333 | 0.0882 | 9 / 9 |

All candidates fail the frozen no-fall condition. The wider runs collect more
transitions under the same ceilings, and their actuator-space exploration is
larger, so the change cannot be attributed solely to deterministic action
capacity. No servo gain, body model, scoring threshold or reference motion was
changed to obtain the result.

During stochastic training, 386/470/472 episodes reached the two-second limit
for seeds 0/1/2, out of 1920/1920/1908 episodes. This is distinct from deterministic
selected-policy qualification; none of its final trials passed. The results
motivate a controlled exploration/noise study and more varied training goals,
as well as collecting the newer upright/contact trajectories for dynamics.
Seeds 200–202 are now inspected development conditions too.
