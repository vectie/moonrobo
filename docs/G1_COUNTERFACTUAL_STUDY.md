# G1 Critic Encoding And Counterfactual Physics Data

Updated: 2026-10-23. This follows the [failure-tail and horizon ablations](G1_DIAGNOSTIC_ABLATIONS.md).
The study measures critic origin sensitivity and tests a 2×2 change to critic
encoding and physical training coverage. It preserves the ten-second control
gate; branch collection time limits are not control qualifications.

## Critic Measurement

The [critic probe](../providers/motion_learning/critic_probe.py) evaluates selected
and latest critics from `g1-invariant-study` on the selected actors' actual
MuJoCo trajectories. Canonical stand/sway/wave cases use reset seeds 760–762;
snapshots at steps 0/50/75/100 are retained only when the episode still exists.
Only value-function inputs are shifted by [1,0], [0,1] and [-1,-1] metres.
The prior physical symmetry probe already measured unchanged motion under such
horizontal translations on this plane. No action or reward depends on an
arbitrary horizontal origin in this experiment.

| Selected critic seed | States | Mean value | Mean recorded soft return | Mean absolute return error | Maximum absolute value change under translation |
| --- | ---: | ---: | ---: | ---: | ---: |
| 0 | 30 | 155.71 | 90.03 | 65.68 | 119.08 |
| 1 | 36 | 94.77 | 112.74 | 39.43 | 175.76 |
| 2 | 28 | -76.52 | 87.80 | 164.33 | 200.17 |

Recorded returns recompute the same tracking, balance, height and smoothness
reward, discount 0.99 and analytic soft continuation used in imagination.
Every source episode actually falls, so the tail value is zero without
time-limit censoring. Hard-termination returns are also retained. The latest
critics are scored on the selected actors' trajectories: their error is not an
on-policy value test for their own latest actors. The summaries preserve this
distinction. None of these sampled critic values is within 1% of the ±300 bound;
the measured origin dependence is not simply complete tanh saturation.
The [recorded probe summary](../output/research/g1-critic-probe-summary.json)
preserves checkpoint bindings, denominators and both critic variants.

```sh
moon run --target native scripts/probe_g1_critic.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-invariant-study/policy /absolute/path/to/moonrobo/target/learning/g1-critic-probe
```

The optional `critic_horizontal_translation_invariant` configuration masks
normalized root X/Y in `Critic.forward`. Warm-starting explicitly projects the
first layer's X/Y coefficients to zero, and records whether the encoding changed.
Those saved zero coefficients also preserve the value function for v1 readers
using the original full inputs. Existing configurations retain their previous
computation. Actor observation/action semantics stay unchanged; world-model
parameters remain frozen during policy improvement.

## Actual Physical Branches

The [collector](../providers/motion_learning/counterfactual.py) uses the three
selected invariant-study actors. Reset seeds 800/810/820 respectively cover
the six training cases: standing and constant pose offsets at three friction
values. At 1.0 and 1.5 seconds, each parent stores its full MuJoCo integration
state, actual preceding action and constant goal.

Each origin spawns an unperturbed branch and a paired positive/negative pulse.
The seeded pulse is Gaussian with 0.04 rad standard deviation, clipped per joint
to ±0.08 rad, held for eight steps, then removed. The actor continues closed-loop
in every branch. Applied actions obey actuator limits and are recorded after
clipping. A pulse may extend outside the actor's ±0.3 rad residual bound; that
bound for the actor itself is unchanged. No learned model supplies labels.

Branches run at most 64 steps (1.28 s) and stop immediately on the same actual
fall criteria. The first transition retains its parent's elapsed time, so an
episode can start at 1.0 or 1.5 seconds. The final finite branch cap is a
truncation; a fall is termination. Each branch is a separate episode, with its
parent ID/step and pulse metadata. Source-family ownership remains training-only.
No windows cross a restored branch boundary or enter held-out families.

All 36 requested origins exist across 18 parent episodes. Collection yields
108 branches and 4306 transitions, including 559 transitions at or after two
seconds. There are 102 falls and six branch time limits. Zero-pulse branches
exactly reproduce their parent state/action/observation transitions (maximum
error zero). The short time limits are not ten-second passes. Branches share
parents and are correlated; they are not 108 independent reset trials.

Merged with the previous 156 episodes/12043 transitions, this adds training
coverage while keeping the prior validation/test numeric arrays and window
references exactly unchanged. The independent model fits retain the prior
128-wide architecture, translation encoding, 400 updates, train-only statistics,
half late-window sampling and validation weighting. Statistics change with the
new training data, so model errors across these fits need a common scale before
comparison.

## Factorial Policy Protocol

All four configurations are written before collection or fitting:

| Experiment ID | Replay and fitted world model | Critic X/Y input |
| --- | --- | --- |
| `branch-old-xy` | Original long-study replay and invariant model | Included |
| `branch-old-invariant` | Same original inputs | Masked |
| `branch-new-xy` | Original plus physical branches, refitted invariant model | Included |
| `branch-new-invariant` | Same augmented inputs | Masked |

Every cell starts from the same three selected invariant-study actor/critic
checkpoints, with optimizer state reset. The masked cells additionally project
the critic's two input columns, as explicitly recorded. Actor normalization
buffers and weights are retained. Each cell runs 200 updates, batch 64, horizon
32, terminal actor critic bootstrap enabled and the same reward/action bounds.
Physics validation uses seeds 30–32 at updates 0/50/100/150/200. The initial
actor remains eligible; no final-test metric selects weights.

Final seeds 770–772 give nine canonical ten-second-maximum physics trials per
candidate. Qualification still requires zero falls and mean joint RMSE ≤0.15
rad. This measures local development quality; unequal collection/fitting costs
prevent a matched end-to-end speedup claim. The data factor changes replay and
its fitted model together, rather than identifying either effect separately.

```sh
moon run --target native scripts/fit_g1_counterfactual.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-long-dynamics /absolute/path/to/moonrobo/target/learning/g1-invariant-study /absolute/path/to/moonrobo/target/learning/g1-counterfactual-study /absolute/path/to/moonrobo/target/learning/experiment-book/moondata
```

Use a fresh output directory and new experiment IDs for a different study.
The script archives numerical providers, writes the frozen charter/configs,
collects actual branches, materializes and checks MoonBit windows, fits three
models, trains all four cells, and registers every completed cell with all
selected/latest weights and failed traces. Existing MoonData payload storage
handles the shared data; there is no new job service or deployment path.

## Recorded Outcome

The merged collection contains 264 episodes and 16349 transitions. MoonBit
produces 12651 train, 934 validation and 916 test windows of length eight.
Training windows starting at or after two seconds grow from 26 to 270; the
held-out late-window counts stay at eight and three. Held-out arrays and window
references are exactly unchanged. All three new dynamics fits beat persistence
globally and on these sparse held-out late windows, with gradient/reload checks
passing. These are prediction diagnostics, not control passes.

| Cell | Selected updates, seeds 0 / 1 / 2 | Mean survival, seeds 0 / 1 / 2 (s) |
| --- | --- | --- |
| Old replay / X/Y included | 0 / 0 / 0 | 1.9644 / 2.3222 / 1.8844 |
| Old replay / X/Y masked | 0 / 0 / 0 | 1.9644 / 2.3222 / 1.8844 |
| New replay / X/Y included | 0 / 0 / 0 | 1.9644 / 2.3222 / 1.8844 |
| New replay / X/Y masked | 0 / 0 / 100 | 1.9644 / 2.3222 / 2.0111 |

Only the combined change selects an updated actor, for seed two. Its mean
joint RMSE rises from 0.12059 to 0.16333 rad, above the 0.15 rad gate. Every
selected candidate in every cell still falls in 9/9 trials. The best incoming
actor remains the best selected actor. Most evaluations repeat the same three
incoming controllers; the table is not evidence from 12 independently improved
controllers. The [compact result](../output/research/g1-counterfactual-study-summary.json)
retains all cells, sample counts and catalog validation.

An independent [critic probe after the change](../output/research/g1-counterfactual-critic-probe-summary.json)
uses the same physical protocol on the combined-change selected actors. Both
selected and latest critics now have exactly zero value change under every
tested horizontal shift. Return calibration remains poor: selected critics'
mean absolute soft-return errors are 66.57/19.28/55.44. The first two actors are
unchanged, while seed two's state distribution differs; do not interpret all
three errors as a paired causal comparison. The latest seed-one critic has mean
value 289.95 versus physical return 112.74 on the selected actor's states, and
83.3% of its sampled values are within 1% of the bound. It is an off-policy
diagnostic, not proof about its own latest actor's returns, but it confirms that
origin masking alone does not calibrate model-trained values to physics.

All four completed cells are registered under the IDs above in the research
RoboBook's MoonData. Their original reports, selected/latest weights, shared
datasets and physical traces remain available through the existing inspector.
Full root validation reports zero findings; all physical execution flags remain
false. Fifteen numerical tests pass, covering actual restored branch replay,
parent elapsed time, action-pulse removal, previous-action observations, true
termination versus branch truncation, recorded hard/soft returns, and critic
translation/reload semantics in addition to prior learning tests.
Both new MoonBit scripts pass `moon check`; `moon info` has zero errors and
scoped formatting completes. Existing toolchain warnings remain. This study
does not change a MoonBit package interface or the cockpit implementation.

The local disk filled while staging the third cell's dataset for registration.
The original process terminated with three completed policy reports. Old
materialized training batches for `g1-policy-feedback`, `g1-policy-warm-native`
and `g1-goal-dynamics` are now losslessly stored as `train-batch.json.gz`; the
later actor-update study also archives the old `g1-long-dynamics` batch this way. Raw
datasets, model/actor weights and reports are retained. The feedback batch was
regenerated and its original SHA-256 verified before compression. Use `gzip -d`
on the required archive before reusing an old batch directly.

Only the never-started fourth cell was trained after freeing space, using the
frozen config and archived numerical provider. Completed training was not
restarted. The already completed cells were reused and imports completed;
held-out equality and full payload validation were checked again. This was a
local recovery action, not a new production job-resume capability.

The subsequent [physics-return critic study](G1_PHYSICS_CRITIC.md) now replaces
imagined critic targets with recorded physical returns in a paired experiment.
Independent scalar-value errors improve, but no updated actor is selected and
all still fall. More data and exact translation symmetry have not resolved
long-duration balance. A reliable controller, matched efficiency and the full
phase acceptance remain open. General service hardening stays deferred.
