# G1 Actor/Critic And Physics Feedback

Implemented: 2026-10-23. The local workflow now optimizes an actor through a
frozen dynamics model, fits a bootstrapped critic, scores checkpoints in MuJoCo,
collects fresh policy trajectories, and refits dynamics. Control qualification
initially failed for every seed, although later model correction and weight warm
starts improve survival. The subsequent [goal-coverage/refinement study](G1_GOAL_COVERAGE.md)
has one independently repeated two-second pass; its extended ten-second trials
all fail. This is not long-term stability or physical qualification.

A [PPO baseline and shared-suite comparison](G1_PPO_BASELINE.md) now scores
these selected warm-start checkpoints on the same fresh evaluation conditions
as PPO. All still fall; longer survival and lower tracking error do not identify
the same method. This is not a matched learning-speed result.

## Run

First create the inputs using the [dynamics fitting workflow](G1_DYNAMICS.md).
Then run from the repository root:

```sh
moon run --target native scripts/fit_g1_policy.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-dynamics /absolute/path/to/moonrobo/target/learning/g1-policy-feedback
```

The MoonBit script owns invocation and result checks. The numerical provider is
[`policy.py`](../providers/motion_learning/policy.py); settings are fixed in
[`g1-policy-fit.json`](../examples/learning/g1-policy-fit.json). It uses one
previously fitted world model (`dynamics-seed-0.pt`) for three actor seeds. This
does not represent three independently trained world-model/controller pairs.

The output keeps the same data/batch/fit layout as the dynamics input, so a new
output directory can serve as the dynamics source for the next local round.
Without an optional fourth argument, rounds initialize a new actor and critic.
Pass a prior policy directory to preserve selected actor/critic weights and
normalization; optimizer moments reset. The prior actor participates in validation
selection, so new updates can retain it. Metadata records the prior checkpoint
digest and selection step. This is weight warm-starting, not exact recovery.
Continuous optimizer-state training and an unattended job service remain future
work.

Use the native script target for larger rounds. The default Wasm script exhausted
memory during the fourth data merge; native execution completed that same round.
This remains in-memory: its train JSON batch is about 535 MiB, not streaming data.

## Learning Computation

The actor receives 93 proprioceptive channels and the current 29-joint goal.
It has two 128-wide SiLU hidden layers and outputs a bounded residual of at most
0.08 rad around each goal, clipped to actuator control limits. Normalization
uses training observations and goals only. The initial zero residual reproduces
the position-reference behavior. This is a current-goal prototype, not the
paper's ten-frame history/future-reference encoder.

Model rollouts reconstruct joint positions/velocities, projected gravity, root
angular velocity and previous actions from simulator-state tensors. Reconstruction
is checked against the collector's actual observations. MuJoCo evaluation passes
only its observed proprioception and goal to the actor; privileged state/context
are used by the dynamics model and critic during learning.

Each of 200 actor updates starts 64 imagined rollouts from training replay states
and differentiates through 32 steps of the frozen dynamics model. The current
goal is held constant during each imagined rollout. Reward combines joint
tracking, upright orientation and nominal root height, with action-smoothness
regularization. Analytic soft survival uses the experiment's fixed 0.35 m height
and 0.5 upright-Z fall thresholds. Discount is 0.99.

A privileged-state critic estimates return beyond that horizon. Its weights are
frozen during the actor update, preserving derivatives through its state input.
Critic fitting uses detached imagined states and GAE targets, lambda 0.95, two
epochs and four shuffled minibatches per epoch. Numerical tests independently
check that physical termination removes bootstrap value and a time limit retains
it.

The positive per-step reward is at most three. Critic values are bounded with
a scaled tanh using `3 / (1 - gamma) = 300`; imagined objectives are checked
against that bound. An initial unconstrained run produced rapidly increasing
critic values without better physical behavior. Bounding the value fixes that
numerical failure, but does not establish world-model accuracy.

The dynamics weights are compared before and after actor optimization, actor
parameters must actually change, and saved/restored actors must produce identical
inference outputs on probe observations.

## Independent Selection And Current Result

Every 50 updates, candidate checkpoints run in MuJoCo on validation references
and seeds 10-12. Selection ranks fewer falls first, then longer survival, then
lower tracking error. The initial actor is included as update zero. No candidate
is selected from learned-model return or from final-test scores.

Final scoring uses seeds 20-22 on the three fixed procedural cases, up to two
seconds per trial. This suite is a development regression experiment, not proof
of broad generalization; it has been inspected during algorithm development.

Initial feedback round:

| Actor training seed | Selected update | Final falls / trials | Mean survival (s) |
| --- | ---: | ---: | ---: |
| 0 | 0 | 9 / 9 | 1.24 |
| 1 | 0 | 9 / 9 | 1.24 |
| 2 | 0 | 9 / 9 | 1.24 |

The position-reference baseline also falls in 9/9 trials, with 1.24 s mean
survival. Learned updates increase imagined return but reduce validation
survival to roughly 1.20-1.22 s. Selection therefore retains the initial actor
in that round. `any_qualified` remains false. No result establishes stable
balance, a PPO efficiency gain, or hardware readiness.

## Model Correction And Warm Starts

With the same settings, the second feedback round selected trained actors,
giving mean survival 1.320/1.316/1.300 s for seeds 0/1/2. A third round that
restarted actors from zero regressed to the initial 1.24 s behavior.

The next experiment used third-round dynamics and explicitly warm-started the
actors/critics selected in round two:

```sh
moon run --target native scripts/fit_g1_policy.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-policy-round-3 /absolute/path/to/moonrobo/target/learning/g1-policy-warm-native /absolute/path/to/moonrobo/target/learning/g1-policy-round-2/policy
```

| Training seed | Selected update in warm-start round | Final falls / trials | Mean survival (s) | Mean joint RMSE (rad) |
| --- | ---: | ---: | ---: | ---: |
| 0 | 200 | 9 / 9 | 1.4844 | 0.1154 |
| 1 | 150 | 9 / 9 | 1.4533 | 0.1200 |
| 2 | 100 | 9 / 9 | 1.4711 | 0.1203 |

Survival improves over the 1.24 s baseline, with worse tracking error than its
0.0971 rad. All candidates still fail the two-second no-fall criterion. This
development suite has been inspected across rounds; generalization claims need
fresh evaluation conditions.

The [physical model probes](G1_MODEL_DIAGNOSTICS.md) compare predictions and
action sensitivities on nominal and learned-policy states, exposing coverage
and scale-dependent contact derivatives. Autodiff correctness alone does not
prove physical gradient quality.

The model was validated on eight-step logged-action predictions, while actor
training imagines 32 steps under changing actions. Prediction error, derivative
error and distribution shift can all matter in that longer closed loop. The
current results motivate on-policy model correction rather than more claims
based on the short-horizon prediction metric.

## Fresh Data And Artifacts

`policy/actor-seed-N.pt` contains the selected inference actor and critic.
`latest-actor-seed-N.pt` preserves the latest trained actor even when selection
rejects it, for diagnosis and exploration. Neither file grants execution
authority. Per-seed physics reports preserve baseline and selected-policy traces;
`policy/report.json` links settings, model/provider digests, selection, learning
history and qualification results.

The script uses the latest seed-zero actor, fixed in advance, to collect fresh
training-family trajectories with exploration. This produced 36 episodes and
2160 transitions, all ending in falls. Episode IDs include the policy digest;
reference-family split ownership is retained. The script writes a new derived
dataset, preserving the original source files. Only train episodes are appended;
validation/test state windows are checked against the original inputs.

The derived collection has 96 episodes and 5871 transitions. MoonBit produces
3879 train, 658 validation and 662 test windows. Dynamics is then fitted again
on the enlarged training set; all three models still beat persistence and pass
the gradient/reload diagnostics. New normalization is fitted to the new training
data, so normalized errors from different rounds must not be compared directly
without a common scale.

The warm-start round added 36 training episodes and 2669 transitions. Its replay
has 204 episodes and 12846 transitions; the reader produced 10098 train, 658
validation and 662 test windows. Dynamics refitting and diagnostics completed
using native execution. The failed Wasm merge is not counted as completed work.

The workflow is local research feedback, not the complete SuperMimic training
system. Remaining work includes further policy optimization, stronger model
coverage/gradient quality, a stable
controller, a matched PPO cost-to-target comparison, and the complete skill workbench. The first and latest
completed rounds now have [MoonData registration and a read-only platform API](LEARNING_EXPERIMENT_REGISTRY.md).
General
checkpoint recovery, retention and deployment hardening remain deferred.
