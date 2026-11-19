# G1 Finite-Task Temporal Value And Policy Updates

Updated: 2026-10-23. This follows the [dynamic model refit](G1_DYNAMIC_REFIT_STUDY.md).
A temporal value model now learns actual remaining-task returns and supplies
an optional tail to H32 policy updates. Initial independent value MAE falls
by approximately 62–93%, and four of six initial on-policy parameter directions
improve remaining physical return with the tail. The full training comparison
still produces no qualified policy: five of six tail-enabled actors retain
update zero, and every selected actor fails all three canonical wave trials.

## Value Inputs And Task Boundary

The value network receives privileged simulator state, ten causal observations,
the current and ten planned future joint goals, friction/actuation context and
seconds remaining until the original ten-second task end. Both frame and preview
actors use this same value input shape. The actors' own observations remain
unchanged (H1/F0 or H10/F10); simulator state is training-only critic input.

State/action units remain inherited from the selected mixed-data dynamics fit.
Observation/goal normalization comes from the incoming actor. State X/Y are
masked; neither the observation history nor joint references contain absolute
horizontal position. The MLP is 128/64 wide, with a zero initial output head.
No reference encoder/shared-decoder equivalence to the paper is claimed.

The target is the discounted sum of actual tracking/balance/height/smoothness
rewards, with the existing soft continuation weight and zero tail after a real
fall **or the original task end**. Remaining time is an explicit value input,
so a five-second state is not silently interpreted as a fresh ten-second task.
The value bound is the discounted maximum remaining reward; expired time and
fallen states return zero. This is a finite-task study, not an estimate of an
infinite continuing-task value. It does not establish sustained thirty-second
control.

During actor imagination, the causal history and known reference advance on
each step. Terminal value receives the predicted state/history, the terminal
current/future reference and correctly reduced remaining time. Actor starts
leave at least H32+1 control periods before the task boundary. Dynamics and
value parameters remain frozen during actor backpropagation; gradients through
their inputs stay enabled. As before, the learned rollout uses soft continuation,
while the physical rollout stops at the actual fall.

`moonrobo.g1-temporal-actor.v1` remains the actor inference format. Optional
`critic` weights, `critic_spec` and `critic_status=finite-horizon-physical-return`
now preserve the selected or latest value network alongside it. Without that
optional payload, existing actor saves retain their old fields/behavior.
Actor/value reload actions and values match exactly. Actor runtime still needs
only the declared temporal actor runner; no hardware interface is added.

## Matched Initial Calibration And Training

Four cells compare frame/preview × tail off/on, each with policy seeds 0/1/2.
All use mixed-data world-model seed zero, fixed before this study. Both tail
arms collect and fit a critic before actor update 1 and again after updates
20/40/60/80, including the off arm which does not use its value in the actor
objective. Each refresh has nine actual train-family episodes and 600 Adam
critic updates at batch 256. There are 540 training episodes and 216 separate
initial/selected audit episodes across the study; no audit targets fit weights.
Failed episodes and applied controls are retained in compressed source records.

Train cases are stand, independent pose goals and independent joint sinusoids
at friction 1.0/0.8/0.6. Canonical sway/wave families are not collected. A refresh
uses reset seed `5000 + 10000 * policy_seed + refresh_index`. Initial independent
value audit uses `5300 + 10000 * seed`, selected-value audit `5400 + 10000 * seed`.
Both are fresh reset seeds inside the training motion families, not a broad
unseen-motion value benchmark. Correlated time points remain correlated.

Initial actor weights, physical calibration dataset hashes, training errors,
independent before/after audit errors and actor validation are identical between
on/off arms within each input variant. Both arms also share the exact teacher
replay tensors. After actor updates diverge, their subsequent own-policy data
can diverge; the later comparison measures the resulting workflow.

Each actor has 100 Adam updates at learning rate 0.0001, batch 64 and H32. Half
the starts come from the shared 36-episode teacher dataset and half from the
most recent own-policy collection, using separate seeded actor/critic samplers.
Validation physics seeds 30–32 choose among updates 0/1/5/10/20/40/60/80/100.
Fresh final seeds 9100–9102 never select weights. Training time includes initial
calibration/direction probes but excludes some final audits/scoring; it is not
an efficiency comparison with PPO.

## Independent Value Accuracy And Physical Direction

Initial independent MAE is measured on the same audit trajectories before and
after the first calibration. It is identical in both tail arms:

| Actor inputs / seed | Zero-value MAE | Calibrated MAE |
| --- | ---: | ---: |
| Frame / 0 | 220.103 | 15.343 |
| Frame / 1 | 180.911 | 49.570 |
| Frame / 2 | 203.904 | 33.486 |
| Preview / 0 | 227.304 | 17.691 |
| Preview / 1 | 177.266 | 67.319 |
| Preview / 2 | 196.962 | 39.102 |

MAE units are discounted reward, not seconds or radians. Residual errors are
still substantial for several actors. Selected-value audits use the selected
actor and different reset seeds; they are retained separately and must not be
treated as a before/after estimate on unchanged trajectories.

The initial direction probe takes a fresh Adam step on actual collected origins,
using the calibrated value only in the on arm. It restores simulator integration
state, causal memory and absolute reference phase. Baseline state/action error
is zero to the declared 1e-8 tolerance. Local returns stop at H32 or an earlier
fall; remaining returns stop at the original task end or fall. Snapshot origins
overlap, and this is a parameter-direction diagnostic, not policy qualification.

| Inputs / seed | Off local Δ | On local Δ | Off remaining Δ | On remaining Δ |
| --- | ---: | ---: | ---: | ---: |
| Frame / 0 | +0.01999 | −0.00333 | +0.18886 | +0.41812 |
| Frame / 1 | +0.00788 | +0.00517 | −0.37485 | +0.79674 |
| Frame / 2 | +0.00182 | +0.00058 | −0.20471 | +0.13315 |
| Preview / 0 | +0.15101 | +0.01071 | +1.16940 | −0.61742 |
| Preview / 1 | +0.10485 | +0.05800 | +0.85213 | +2.16979 |
| Preview / 2 | −0.06503 | −0.05357 | −1.04594 | −0.62915 |

Remaining return improves in 4/6 on versus 3/6 off actor-origin batches, while
local return improves in 4/6 versus 5/6. Initial frame directions benefit in
remaining return even where local return decreases. Preview seed zero does the
opposite. Accurate values and useful directions are separate empirical checks.

## Full Training Still Fails Qualification

| Cell / seed | Selected update | Baseline → selected survival (s) | Selected RMSE (rad) | Falls / 9 |
| --- | ---: | --- | ---: | ---: |
| Frame off / 0 | 40 | 7.5467 → 7.5822 | 0.05218 | 3 |
| Frame off / 1 | 40 | 7.4689 → 7.4844 | 0.05185 | 3 |
| Frame off / 2 | 5 | 7.6733 → 7.6778 | 0.04348 | 3 |
| Frame on / 0 | 0 | 7.5467 → 7.5467 | 0.04567 | 3 |
| Frame on / 1 | 0 | 7.4689 → 7.4689 | 0.04648 | 3 |
| Frame on / 2 | 0 | 7.6733 → 7.6733 | 0.04436 | 3 |
| Preview off / 0 | 60 | 7.2400 → 7.5111 | 0.05397 | 3 |
| Preview off / 1 | 20 | 6.8400 → 7.3844 | 0.05240 | 6 |
| Preview off / 2 | 10 | 7.3333 → 7.3289 | 0.04772 | 3 |
| Preview on / 0 | 1 | 7.2400 → 7.5311 | 0.04622 | 3 |
| Preview on / 1 | 0 | 6.8400 → 6.8400 | 0.05022 | 7 |
| Preview on / 2 | 0 | 7.3333 → 7.3333 | 0.04750 | 3 |

All selected policies fall in all three wave trials. Preview seed-one also
retains standing failures; its on arm has one sway fall. Five of six on actors
retain update zero, which means an unchanged incoming actor with a calibrated
value payload, not a newly learned control success. No actor reaches the frozen
zero-fall, mean-RMSE ≤0.15 rad gate, so no longer qualification follow-up runs.
Later update histories retain substantial validation regressions.

The subsequent [replay-distribution study](G1_REPLAY_DISTRIBUTION_STUDY.md)
compares teacher/current/mixed directions with fixed actor/value/model/origins.
Teacher-only has the most positive remaining-return directions with the tail,
but its subsequent repeated-update study still fails every wave trial. Exact
saved first-step reconstructions confirm both interventions. Replay alone does
not resolve sustained policy improvement. A physical temporal-PPO baseline is
the next bounded comparison against model/value-gradient updates.

## Platform Evidence And Reproduction

The [verified report](../output/research/g1-temporal-value-study.json) retains
paired initial equivalence, every calibration/audit, physical direction records,
validation histories, fresh per-case outcomes and immutable payload refs. The
registered IDs are `temporal-frame-value-off`, `temporal-frame-value-on`,
`temporal-preview-value-off`, `temporal-preview-value-on`. Selected/latest
actor/value pairs, world-model weights/reports, shared replay and compressed
training/audit physics are stored through the existing read-only API/cockpit.
Initial direction weight files remain local diagnostics with report hashes.
MoonData full validation has zero findings. Registration confers no authority.

```sh
moon run scripts/fit_g1_temporal_value.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-temporal-input-study /absolute/path/to/moonrobo/target/learning/g1-dynamic-refit/mixed /absolute/path/to/moonrobo/target/learning/g1-temporal-value-study
moon run --target native scripts/report_g1_temporal_value.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-temporal-value-study /absolute/path/to/moonrobo/target/learning/experiment-book/moondata /absolute/path/to/moonrobo/output/research/g1-temporal-value-study.json
```

Use a fresh training directory. Scripts archive sources/config and freeze the
charter before workers start. All 37 numerical and ten relevant MoonBit tests
pass. New regressions cover terminal/expired value, XY invariance, history/future
sensitivity, paired reload, unchanged no-tail imagination, terminal reference
phase, reduced time and gradient propagation. `moon info` and scoped formatting
leave the public MoonBit package API unchanged in this slice.

For storage, completed sustained/temporal/short-cycle/paired-tail source physics
JSON files and the older balance-teacher dataset/reports were losslessly archived
as `.json.gz`. Weights, top-level learning reports and registered BlobStore data
remain intact. Restore an archived old path with `gzip -d` before workflows
that still require its raw name. Completed G1 script compilation caches were
removed; `moon run` rebuilds them. Current temporal teacher replay stays raw.

Stable learned control, matched PPO efficiency, the complete workbench/E1 phases
and physical qualification remain unfinished. General production hardening is
deferred; this slice adds no hardware path or generic job/recovery framework.
