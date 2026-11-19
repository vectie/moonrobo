# E1 regression and G1 comparison — 2026-11-11

The regression after iteration 4000 is reproducible, but 4000 is not a demonstrated optimum. Iteration 6500 recovers all five training motions and improves their mean return. Evidence points to changing policy behavior and long-rollout fragility, alongside concrete data, task and training mismatches with the successful G1 run. There is no evidence of a numerical blow-up or an evaluation/export mix-up. Classical overfitting remains possible but cannot be established from one held-out boxing motion.

Production training was left unchanged. Controls used CPU-only containers, two CPUs and 8 GiB memory, with the production job mounted read-only. Reference analysis ran on 178; checkpoint controls ran on 179.

## Curves and checkpoint selection

Scores are fixed full-duration normalized returns. Completion is the existing height/tilt termination criterion, **not strict trajectory tracking**. Training evaluation uses all five admitted training clips; validation has one boxing clip.

| Checkpoint | Train mean | Train complete | Validation mean | Validation complete |
|---:|---:|---:|---:|---:|
| 2000 | 0.522815 | 5/5 | 0.559635 | 1/1 |
| 3000 | 0.416990 | 3/5 | 0.418047 | 1/1 |
| 4000 | 0.655367 | 5/5 | 0.561275 | 1/1 |
| 4500 | 0.581195 | 4/5 | 0.428225 | 1/1 |
| 5000 | 0.645478 | 4/5 | 0.424260 | 1/1 |
| 5500 | 0.658126 | 4/5 | 0.445737 | 1/1 |
| 6000 | 0.602108 | 3/5 | 0.518309 | 1/1 |
| 6500 | 0.709351 | 5/5 | 0.473342 | 1/1 |

There was a similar dip at 3000. At 5500 sprint terminates after 10801/13655 steps, whereas 6000 completes sprint but loses walk and the end of run. At 6500 every training motion completes again. This is not uniform degradation of every skill.

Replay world-model eight-step error and critic loss continue decreasing through the collected log (approximately iteration 6280); imagined reward rises. These are changing-replay and short-horizon metrics, not fixed validation curves. The 32-step imagination horizon is 0.64 seconds. Learning-rate decay is smooth, without a discontinuity at 4000.

Artifacts: [evaluation curves](../output/e1-regression-audit-20261111/evaluation-curves.png), [training curves](../output/e1-regression-audit-20261111/training-curves.png), [distribution curves](../output/e1-regression-audit-20261111/distribution-curves.png), [machine-readable analysis](../output/e1-regression-audit-20261111/analysis.json).

## Controlled checks

1. Repeating the original 4000 and 5500 held-out boxing and sprint evaluations reproduces their original scores and durations exactly. Evaluation noise does not explain these differences.
2. Held-out boxing with 4000 weights and their original normalizers scores 0.561275; 5500 weights with their normalizers score 0.445737. Giving 5500 weights the 4000 observation/goal normalizers scores only 0.237888. Giving 4000 weights the 5500 normalizers scores 0.536676. At fixed 5500 normalizers, 4000 weights still outperform 5500 weights. A normalizer rollback is not a remedy; policy weight changes matter. These swaps do not isolate the optimizer, replay or world-model cause of those weight changes.
3. A fixed held-out physical corpus (32 windows of eight MuJoCo transitions, generated once with actor 4000 and fixed action noise) tests saved world models in common physical units. Eight-step joint position RMSE improves from 0.11574 rad at 4000 to 0.10216 at 5500; root-position RMSE improves from 0.02373 m to 0.01927 m. Rotation component RMSE changes from 0.07243 to 0.07549 rad. This disfavors a broad world-model overfitting collapse on this probe. It is only 256 transitions from one motion, not a global model validation.
4. Eighteen reference-state-reset segments (three starts each in sprint and walk, ten seconds each, at 4000/5500/6000) all survive. Later policies often score better locally even when their full-motion evaluation fails. For sprint starting at frame 10300, segment scores are 0.7163/0.7691/0.7788. This supports accumulated deviations over long rollouts rather than universally worse local control.

Reports: [control directory](../output/e1-regression-audit-20261111/controls/), [world-model probe](../output/e1-regression-audit-20261111/controls/fixed-world.json), [segment probe](../output/e1-regression-audit-20261111/controls/segments.json).

Checkpoint identities, actor/checkpoint normalizer bindings, actor source checkpoint hashes, export/report hashes, evaluation protocols, runtime library hashes and clip lengths agree across the collected series. Additional actor-readiness physical collection is zero. The live executable, configuration, dataset/admission and runtime hashes matched their frozen launch identities. No OOM was observed. Collected evaluation coverage ends at 6500; training-log plots end earlier.

## What differs from the actual successful G1 run

The prior justification matched paper ratios, but did not reproduce the actual successful G1 learning dynamics. That distinction matters.

| Quantity | Successful G1 | Current E1 |
|---|---:|---:|
| Training motions | 137289 BONES-SEED motions | 5 admitted motions |
| Physical environments | 256 | 128 |
| New physical transitions per iteration, nominal | 640 | 1280 |
| World batch × updates | 2048 × 10 | 256 × 10 |
| World windows per new physical transition | 32 | 2 |
| Actor batch × imagination horizon | 4096 × 32 | 512 × 32 |
| Imagined transitions per new physical transition | 204.8 | 12.8 |
| Replay capacity | 256000 | 128000 |
| Nominal replay residence in iterations | 400 | 100 |
| Learning-rate decay budget | 250000 | 14000 |
| Training episode limit | 10 s | 10 s |
| Evaluation motion unit | 40 short training-catalog motions, 7.62 s average | Four full capture files, 244–273 s, plus boxing |
| Reported quality | 38/40, 0.86358, training panel | Separate training panel and one held-out boxing clip |

World windows count sampled eight-step windows, not individual transition slots. G1 therefore uses 16 times more world windows and imagined transitions per new physical transition, eight times larger global batches, and four times longer replay residence in optimizer iterations. These differences are measured configuration differences, not proof that copying all G1 values will fix E1. Memory and throughput must be measured before any such trial.

G1 also uses APIC/Newton physics and compiled BF16 execution; E1 uses native MuJoCo and FP32 with smaller microbatches. The robot, corpus, split, physical engine and execution are not controlled variables. G1's 38/40 panel is not a held-out generalization result. See [G1 final report](../output/bones-bf16-production-20261109/long-final-report.json) and [predeclared panel](../output/bones-bf16-production-20261109/panel-predeclared.json).

## Concrete motion and task problems

### Retargeting adds acceleration without an admission gate

Source G1 CSV hashes were verified against the admitted dataset. Source and E1 motions were both evaluated through the same motion library at 50 Hz. Central-difference kinematics show that E1 retargeting amplifies root acceleration and joint acceleration. Representative 95th percentiles:

| Motion | Root linear acceleration, source → E1 (m/s²) | Root angular acceleration, source → E1 (rad/s²) |
|---|---:|---:|
| Jump | 9.25 → 20.03 | 23.05 → 78.29 |
| Run | 7.50 → 31.16 | 31.70 → 113.38 |
| Sprint | 6.72 → 32.30 | 31.78 → 134.00 |
| Walk | 3.22 → 19.37 | 9.78 → 69.83 |

For walk, the 95th percentile of per-frame maximum joint acceleration rises from 77.27 to 227.79 rad/s². The existing fit constrains poses, collisions, joint limits and joint velocity, but does not bound root or joint acceleration or check inverse-dynamics/contact-force feasibility. Its geometric admission is insufficient to call the data dynamically qualified.

This is evidence of added temporal roughness, not proof of infeasible contact forces, nor proof that one spike caused the post-4000 drop. Native source motions themselves also contain transients. The next data revision needs temporal regularization and derivative checks followed by torque/contact feasibility testing; checking a few poses cannot establish those properties. [Full reference dynamics report](../output/e1-regression-audit-20261111/reference-dynamics.json).

### Global path tracking is not observable to the actor

The selected 99D SMC observation omits reference-relative root translation. The goal uses future reference positions relative to the current **reference** pose, not to the actual robot position. Translating the robot horizontally while keeping orientation, joints and history fixed produces identical policy inputs. Only the separate 102D observable mode adds position-error feedback.

Termination checks height and tilt only; the body-position reward anchors horizontal coordinates to the agent. At checkpoint 4000, one ten-second sprint segment survives while reaching **6.05 m** root-position error. Thus 6/6 full-duration survival cannot mean strict global tracking. This inherited SMC design is a task mismatch if the intended result is accurate multi-minute global paths; it is not automatically a bug in the original G1 method.

Code: [observation and reward](../src/learning_aligned/mdp.mbt), [reference goal](../src/learning_aligned/motion.mbt), [selected E1 observation](../src/learning_e1_training/train.mbt). Short-skill imitation and global-path tracking need distinct evaluation criteria. Adding position feedback also requires a deployable localization/state-estimation source; changing the input dimension alone does not solve deployment.

### Sampling and validation are weakly aligned with the task

Adaptive reset probability changes substantially: its total variation from checkpoint 4000 is 0.246 at 5500 and 0.387 at 6000. Sprint reset mass rises from 0.412 to 0.574 by 6000. Boxing receives about 0.2–0.3% of reset probability, but contributes 20% of the equal-clip training score and is the sole held-out action. This is intended duration-bin sampling, not a discovered implementation error, but it can support changing skill tradeoffs. No training ablation has established its causal contribution.

The single held-out boxing clip was slowed approximately 3.15 times during admission. It cannot validate running, walking or jumping generalization. Splits should be made by independent source sequence/subject before segmentation; segments from one recording must remain in one split.

## Decision supported by this audit

Keep both 4000 and 6500 as baseline candidates: 4000 is better on held-out boxing, 6500 is better on all-training completion and mean return. Do not promote either as strict tracking or deployment ready. Iteration count alone is not a valid stopping criterion here.

Before another long run: produce temporally smooth, feasibility-checked E1 references on 178; split independent recordings and segment meaningful skills; define local imitation versus global path goals and corresponding observable inputs/strict metrics. Then run a controlled comparison on 179 with measured batch/replay/update settings, fixed validation and checkpoint selection. A lower actor learning rate or different replay/sampling schedule is a hypothesis for that comparison, not an established fix from these read-only probes.

New diagnostic tooling is isolated under `cmd/e1_regression_probe`, `scripts/analyze_e1_regression.mbtx`, and `scripts/audit_e1_regression_controls.mbtx`. The native probe built and ran world, segment and reference modes. `moon info` and formatting completed; the new command has no public API. Production source, dataset and running trainer were not changed by this audit.
