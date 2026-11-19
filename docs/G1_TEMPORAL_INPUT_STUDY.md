# G1 Temporal Inputs And Changing Reference Rollouts

Updated: 2026-10-23. The actor now supports causal observation histories and
planned future joint commands, including during differentiable imagined
rollouts. Three input variants underwent supervised initialization and then
actual frozen-world-model policy updates. No candidate passes all nine
ten-second physics trials. One frame-only policy completes its first wave
trial, but the other two wave trials still fail. Temporal inputs do not show
a consistent benefit in this experiment.

## Relation To SuperMimic

The [downloaded paper](../output/pdf/supermimic-2610.28480v1.pdf), Appendix C,
Table A.4, describes ten past observation frames for the shared decoder and
ten future reference frames for the motion encoder. Our earlier actor used
only the current observation and joint goal, and its imagined rollout kept
that goal constant. This study implements the corresponding temporal data
path, with substantial remaining architectural differences.

Our goals contain 29 joint targets, without the paper's full reference-body
features or motion encoder/shared decoder. The existing goal-anchored,
bounded residual action convention is retained. An additional two-layer,
64-wide adapter adds to the incoming actor's latent action. Its output head
starts at zero, preserving the incoming closed-loop behavior exactly before
training. These are partial independent implementations, not paper-equivalent
networks or a reproduction of its reported efficiency.

The three variants are `frame` (H1/F0), `history` (H10/F0), and `preview`
(H10/F10). H10 includes the current observation and nine past observations.
Future commands are sampled at +1 through +10 control steps (20–200 ms).
Startup repeats the first observation; offline history restarts at cadence
gaps and cannot cross episode resets. No future physical state or sensor
measurement enters the actor. The runner reconstructs a declared procedural
command schedule and checks that its current command agrees with physics.

The new `moonrobo.g1-temporal-actor.v1` checkpoint declares history/preview
lengths, adapter width, frozen normalization and base configuration. It uses
`TemporalRunner`; the legacy single-frame loader rejects this format. Reload
checks reproduce actions exactly. No deployment runner or hardware bridge has
been added.

## Shared Dynamic Training Conditions

Training retains stand and independently sampled pose targets at friction
1.0/0.8/0.6 and adds independently phased joint sinusoids at those frictions.
Each joint has its own frequency, phase, bias and amplitude; the new family
does not reuse the canonical validation sway or test wave generator. Group
amplitude ceilings are 0.02/0.06/0.12 rad for lower body/waist/upper body.
The selected privileged teacher's exact archived implementation is hash-checked
before queries. This controller is a training-data source, not the learned
policy or a claim of onboard sensing compatibility.

One shared collection contains 36 teacher-controlled episodes and 16,909 actual
transitions: 25 ten-second completions and 11 falls. The native MoonBit data
reader validates this dataset before training. Teacher seeds are 4000–4003.
The teacher already fails some dynamic and pose cases; future references do
not make its labels universally stable.

Each variant starts from the same three incoming aggregation actors. Eight
rounds each collect 18 student-controlled training episodes, query separate
teacher action targets, and perform 750 supervised Adam updates at batch 128.
The objective samples half shared teacher points and half recent student
points, capped at 30,000 recent points. Actual `applied_action` remains the
student's control; teacher targets are stored separately in compressed logs.
All failed episodes remain available. Across nine runs this adds 1296
student episodes, without adding validation/test episodes to supervision.

At sampled positions 0/1/25/100/250/499 where present, collected online actor
inputs and reconstructed offline inputs agree exactly in every round. Three
training seeds, train-only label loading, initial legacy-trace equivalence and
checkpoint reload checks all pass.

Validation physics seeds 30–32 select among rounds 0–8; fresh final seeds
8700–8702 do not select weights. The final suite has stand/sway/wave at three
reset seeds each, ten seconds, with the existing fall and RMSE criteria.
Canonical motions are a repeatedly inspected development suite across the
larger project; this is not evidence of broad unseen-motion generalization.

| Variant / seed | Selected round | Survival (s) | RMSE (rad) | Falls / 9 |
| --- | ---: | ---: | ---: | ---: |
| Frame / 0 | 1 | 7.5489 | 0.04566 | 3 |
| Frame / 1 | 3 | 7.4956 | 0.04627 | 3 |
| Frame / 2 | 4 | 7.6822 | 0.04435 | 3 |
| History / 0 | 6 | 7.5222 | 0.04561 | 3 |
| History / 1 | 2 | 7.4733 | 0.04573 | 3 |
| History / 2 | 0 | 7.3378 | 0.04725 | 3 |
| Preview / 0 | 6 | 7.2444 | 0.04950 | 6 |
| Preview / 1 | 0 | 7.2022 | 0.04849 | 6 |
| Preview / 2 | 0 | 7.3378 | 0.04725 | 3 |

All frame/history actors still fail all three wave trials. Two preview seeds
retain or introduce additional failures. Update-zero selections preserve
their incoming actor rather than constituting newly learned successes.
The verification report independently re-scores the legacy incoming actors
on the same 8700–8702 seeds for before/after comparison.

## Actual World-Model Refinement

Each selected supervised actor then receives 200 model-based updates, batch
64, learning rate 0.0001, through the same frozen sustained-world-model seed
zero. All variants sample the same teacher physical starting points with the
same declared random index seeds. They use their own causal input lengths
and incoming actor weights. The world model is not refit on this new dynamic
collection: its original sustained-dataset training digest stays distinct
from this actor replay's digest.

During each 32-step imagined rollout, the goal advances through its known
analytic schedule, the reward uses the current step's goal, and the actor's
history rolls forward with predicted observations and its own actions.
World-model parameters and normalization stay frozen while action/state
gradients remain enabled. Bootstrap is disabled consistently because no
future-aware critic has been trained. This study estimates a finite-horizon
objective, not the paper's complete actor/critic training loop.

Validation selects updates 0/1/5/10/20/50/100/150/200 using seeds 30–32;
independent final seeds are 8800–8802. The baseline in each registered report
is that variant's incoming supervised actor, evaluated under the same fresh
conditions. It is not a position-controller or PPO baseline.

| Variant / seed | Selected update | Incoming → selected survival (s) | Incoming → selected RMSE (rad) | Falls / 9 |
| --- | ---: | --- | --- | ---: |
| Frame / 0 | 0 | 7.5444 → 7.5444 | 0.04585 → 0.04585 | 3 |
| Frame / 1 | 100 | 7.4778 → 9.2489 | 0.04653 → 0.04220 | 2 |
| Frame / 2 | 10 | 7.6622 → 7.6911 | 0.04449 → 0.04480 | 3 |
| History / 0 | 150 | 7.5200 → 7.5222 | 0.04554 → 0.05373 | 3 |
| History / 1 | 50 | 7.4356 → 7.5444 | 0.04623 → 0.05896 | 3 |
| History / 2 | 10 | 7.3622 → 7.3578 | 0.04696 → 0.04885 | 3 |
| Preview / 0 | 50 | 7.2489 → 7.4889 | 0.04953 → 0.05218 | 3 |
| Preview / 1 | 50 | 7.2156 → 8.6778 | 0.04854 → 0.04986 | 2 |
| Preview / 2 | 50 | 7.3622 → 5.8578 | 0.04696 → 0.06825 | 5 |

The best frame-only run completes seven of nine trials, including one wave
trial. History-only updates increase tracking error for all seeds. Preview
has mixed results, including a large seed-two regression. No method meets the
frozen gate of zero falls across all nine trials and mean RMSE ≤0.15 rad.
None proceeds to a longer-duration qualification follow-up.

Adapters differ in input dimension and parameter count. Supervised collection
diverges with the students, and subsequent model refinement starts from
different selected weights. Thus these are end-to-end workflow comparisons,
not isolated causal estimates for adding history or preview. Parallel CPU
training uses two Torch threads per process, three variant processes; reported
training times exclude some final scoring and are not matched wall-clock or
PPO efficiency evidence.

## Platform Evidence And Reproduction

The [verification report](../output/research/g1-temporal-input-study.json)
retains all validation histories, incoming/final metrics, per-case failure
counts, student-log hashes, model/replay digests and MoonData payload refs.
Actual model-refinement cells register as `temporal-frame`, `temporal-history`
and `temporal-preview` through the existing read-only API/cockpit. Each stores
selected/latest temporal actors, physics traces, the compressed actor replay,
and the reused world-model reports/weights. Standalone supervised training
uses a distinct report format and is not relabeled as model-based training.
Its parent weights, sources and student logs remain local research artifacts;
their full independent registry lifecycle remains incomplete.

```sh
moon run scripts/fit_g1_temporal_inputs.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-balance-teacher-data /absolute/path/to/moonrobo/target/learning/g1-teacher-aggregation/policy /absolute/path/to/moonrobo/target/learning/g1-temporal-input-study
moon run scripts/refine_g1_temporal_inputs.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-temporal-input-study /absolute/path/to/moonrobo/target/learning/g1-sustained-model-study/new-fit /absolute/path/to/moonrobo/target/learning/g1-temporal-refinement
moon run --target native scripts/report_g1_temporal_inputs.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-temporal-input-study /absolute/path/to/moonrobo/target/learning/g1-temporal-refinement /absolute/path/to/moonrobo/target/learning/g1-teacher-aggregation/policy /absolute/path/to/moonrobo/target/learning/experiment-book/moondata /absolute/path/to/moonrobo/output/research/g1-temporal-input-study.json
```

Training scripts require fresh output directories and archive sources/configs
before fitting. Verification checks all compressed log hashes, initial actor
bindings, unchanged world-model weights, input alignment, report/trial counts,
compressed dataset identity and the full MoonData catalog. All 29 numerical
tests and 887 native repository tests pass. Tests exercise causal gaps, seeded
future commands, zero-adapter equivalence, format-specific loading, exact
constant-goal equivalence to the old imagination path and gradients under
changing goals. No public MoonBit package API changes in this slice.

Disk exhaustion interrupted the first registration attempt, after two cells
had been published. No failed registration was counted as completed evidence.
After reclaiming rebuildable test outputs and losslessly archiving old numeric
batches, the verifier retries the existing immutable cell IDs and completes
the remaining import. The retained failed log is
`/tmp/g1-temporal-verification-disk-full.log`.

Additional old collections/batches were archived losslessly as `.json.gz`,
including original dynamics, feedback/warm/goal/long/invariant collections,
four counterfactual and horizon cells, policy rounds 2/3, teacher batches and
the two early policy-loop held-out batches. Weights, reports and registered
BlobStore payloads remain intact. Restore an old JSON path with `gzip -d`
before a workflow that still requires its uncompressed name. The new temporal
teacher replay remains available uncompressed for this experiment.

The subsequent [dynamic-state gradient study](G1_TEMPORAL_GRADIENT_STUDY.md)
tests selected frame/preview parameter directions against restored physical
returns on training-only dynamic states. Four of five nonzero selected changes
worsen remaining physical return despite predicted improvement; dynamic
prediction error exceeds standing. Small and complete parameter displacements
can disagree. This motivates fitting from the already collected dynamic data
before further policy sweeps. These results do not establish temporal input
as the missing cause of stable control. All SM phase acceptance, matched
PPO cost-to-target, E1 adaptation and physical qualification remain open.
