# E1 workflow review against SuperMimic v1

Reviewed 2026-11-11. This is a comparison of the actual E1 implementation and
running experiment, not a claim that a new retargeter or qualified dataset has
been completed. The running job and its immutable artifacts were not changed.

## Conclusion

We implemented a functioning learning lifecycle and then promoted its smoke
data into a long experiment before establishing the target-robot/motion
contract and reference admission criteria. The learner's broad structure is
consistent with SuperMimic, but this does not make the data pipeline or the
experiment equivalent. The current run is an engineering baseline.

The central mistake was conflating three distinct questions:

1. Does the software execute and preserve its artifacts?
2. Do the references describe the intended E1 motion task consistently?
3. Does the resulting policy physically track that task?

Our completed tests mainly answer question 1. They do not establish 2 or 3.

## Paper basis

Primary source: [SuperMimic v1](https://arxiv.org/pdf/2610.28480), Algorithm A.1,
Table A.5, Appendices E and F. Appendix E starts from G1-retargeted BONES-SEED
and filters names and geometric infeasibility. Algorithm A.1 collects simulator
transitions, fits the world model, then updates policy and critic in imagination.
Appendix F evaluates full motions from frame zero on the training benchmark.

The paper does not supply a G1-to-E1 retargeter. Its filtering is not a proof of
complete dynamic feasibility, and its benchmark is coverage, not unseen-motion
generalization. Extra E1 qualification steps below are our engineering proposal.

## Findings, ordered by priority

### P0: Target embodiment was not settled before data conversion

The active importer defaults to 23 joints and fixes waist roll in the supplied
24-axis MJCF. It selects retained source joint columns without compensating
upper-body motion. The source waist-roll amplitude reaches approximately 30°.
Recomputing FK makes the new references internally consistent with the new
kinematic body; it does not show that they preserve the source's task, contacts
or balance relationships.

Source-body pose reconstruction against the original NPZ body positions and
orientations has not been measured independently. Synthetic joint-index tests
confirm our declared permutation, not the source asset/version compatibility.
The official local sim2sim joint-name list agrees with our declared order;
that is useful evidence but does not replace numerical reconstruction.

Evidence: [profile](../src/learning_e1_training/profile.mbt),
[conversion](../src/learning_e1_training/motion.mbt),
[scene preparation](../src/learning_e1_training/dataset.mbt),
[source-amplitude audit](../output/e1-retarget-audit-20261111/reference-quality.json).

Correction: use the unmodified 24-axis vendor embodiment as a source-control
experiment. Independently verify source FK and coordinate conventions, and
bind each target dataset to an explicit 23- or 24-axis robot identity. A
23-axis fit must solve for that constrained body; selection of columns is not
a validated morphology conversion. The physical variant remains unconfirmed.

### P0: Artifact validity was used in place of motion admission

`open_dataset` checks format, profile equality, IDs, split/source hashes, scene
and meshes. `load_motion` checks finite values, dimensions and inactive zeros.
Neither requires a reference-quality acceptance report. `train` proceeds from
those checks directly to allocation, collection and learning. Consequently a
well-hashed but unsuitable reference can enter the experiment.

The post-launch audit found elbow range violations in 2,622/11,245 dance frames,
up to 0.17 rad, and profile-speed exceedances in validation references. These
are incompatibilities with the configured scene/profile. They do not alone
prove the source data is universally bad: a source-model or convention mismatch
must be excluded before deciding whether to refit, retime or reject a clip.
The reset implementation clips physical joint positions to the target limits
while leaving reference targets unchanged, so it cannot repair this data
incompatibility. Changing or clipping the task also requires its own audit.

Our separate IK candidate's `accepted` field checks ankle-body positional error
against 8 cm. It checks neither signed foot-to-floor distance nor extended
unsupported standing. Its only integration fixture is eight stationary frames.
It has not executed the motion-library screening needed by the active dataset.

Evidence: [dataset validation](../src/learning_e1_training/dataset.mbt),
[training entry](../src/learning_e1_training/train.mbt),
[IK candidate](../src/learning_e1_training/retarget.mbt),
[standing fixture](../output/e1-native-20261110/retarget-gate.json).

Correction: separate diagnostic imports from admitted training references.
Admission must bind the scene/profile, transform, per-clip measurements, rules,
accept/reject reasons and accepted IDs. For paper-style feasibility screening,
measure actual foot collision geometry against the floor and preserve the
temporal/standing conditions. E1 thresholds require validation; copying G1
thresholds or treating ankle-origin height as sole clearance is insufficient.

### P0: Training/data balance changed without an experimental justification

The E1 configuration changes environment count and global batch sizes while
retaining UTD 0.4. The runtime defines UTD in vectorized simulator steps.
Microbatch size 64 controls memory inside these already reduced global batches.

| Nominal steady-state quantity | Paper one-GPU configuration | Current E1 |
| --- | ---: | ---: |
| Environments | 4,096 | 16 |
| New physical transitions / iteration | 10,240 | 40 |
| World windows / iteration | 20,480 | 2,560 |
| World windows / new physical transition | 2 | 64 |
| Imagined transitions / new physical transition | 12.8 | 204.8 |
| Replay transition capacity | 4,096,000 | 16,000 |

Thus nominal world-window sampling per new transition is 32× higher and policy
imagination per new transition 16× higher. These are schedule calculations,
not measured unique samples. Initial warm-up, world-only iterations and extra
actor-readiness collection are excluded. This changes data reuse, correlation
and optimizer exposure; it is not evidence by itself that learning must fail.

The launch's actual configuration hash was verified before calculating these
values. `Config::validate` also caps environments at 128 and global batches at
512, so the current entry cannot simply select the original larger settings.

Evidence: [running configuration](../output/e1-retarget-audit-20261111/running-training-config.json),
[reproducible budget calculation](../output/e1-retarget-audit-20261111/paper-budget.json),
[E1 config](../src/learning_e1_training/config.mbt),
[collection/update schedule](../src/learning_aligned_gpu/runtime/train.mbt).

Correction: define the intended physical-transition and optimizer budgets
explicitly. Preserve effective batches through microbatching where appropriate,
or declare and test a smaller configuration. Changing the number called UTD
alone will not reconcile both ratios when the two global batches were reduced
by different factors.

### P1: We changed the experimental question and budget

The active experiment trains on two vendor E1 files, with two separate files
reserved for validation. It does not exercise the G1-to-E1 candidate retargeter
or a broad transferred library. These four clips are valid integration material;
success on them would establish only their declared scope.

The prior G1 BONES catalog was also explicitly paper-partial: 137,289 accepted
clips rather than the paper's 129,514. Its recorded filter lacked a name list
and the floating-feet rule. Transferring that catalog would require a new E1
filtering pass and a clear source-set definition, not inheritance of a generic
"paper data" label. See the existing
[dataset extraction audit](../output/research/supermimic-dataset-extraction.zh-CN.md).

The 14,000-iteration stopping point is not a demonstrated E1 convergence budget.
With the unchanged 250,000-iteration cosine schedule, its learning rate would
still be about 99.25% of the starting rate at that point. The end time predicts
when a job stops; it does not predict that the robot will have learned the task.

### P1: Evaluation currently misses the primary coverage question

The evaluator correctly supports full-duration denominators, frame-zero starts,
no training noise/randomization/timeouts and explicit splits. However, the
executed E1 result is two validation clips from a three-iteration integration
model. It does not establish training-motion coverage of the running model.

Correction: declare a fixed training-coverage panel and run frozen checkpoint
evaluations, then report validation separately. Group original takes and their
related versions before any generalization claim. Retarget residuals, world
prediction loss and policy completion are different metrics. A declining world
loss cannot certify reference preservation or motion-tracking success.

Evidence: [evaluation implementation](../src/learning_e1_training/inference.mbt),
[executed integration evaluation](../output/e1-native-20261110/final-evaluation-23.json).

### P1: Physics/observation adaptations need their own evidence

Current learning uses CPU native MuJoCo physics and CUDA FP32 learning. The
E1 environment randomizes friction and encoder offsets; it leaves the torso-COM
context zero. The actor uses the 99-wide public-code-style observation with a
masked 29-axis internal embedding. These are explicit implementation choices,
not proof of exact paper physics, observation semantics or deployment readiness.
The shared G1 regression results should be retained, alongside E1-specific
FK, reset, observation, action and physical-step checks.

## What is already sound

- Reference goals and simulator replay have separate roles. World-model fitting
  consumes actual simulated transitions and executed actions.
- The learner retains 8-step world fitting, 32-step imagination and imagined
  actor/critic updates. This review found no new evidence that these equations
  are the primary problem.
- Data/code/runtime identities, immutable generations and optimizer artifacts
  are useful and should remain. Hashes prove which experiment ran.
- The display labels its animations as references. They are not policy results.
- Spark 178/179 separation is appropriate; the identified errors concern the
  experiment definition and admission workflow.

## Corrected sequence

1. **Robot/source contract:** establish variant, names, frames, zero/sign
   conventions, collision geometry and actuator scope; verify native FK against
   source records before morphology conversion.
2. **Small controlled data experiment on 178:** use an unchanged source-body
   control, then fit the intended target. Prefer original human motion when
   available; treat G1-to-E1 conversion as an additional transformation whose
   losses must be measured.
3. **Reference admission on 178:** record source/task preservation, contact and
   geometry screening and target-range diagnostics. Freeze a versioned accepted
   catalog, including explicit exclusions and splits.
4. **Bounded learning experiment on 179:** predeclare collection/update budgets
   and evaluation panel. Test standing and representative moving clips before
   expanding the accepted catalog or the run length.
5. **Joint training and checkpoint evaluation:** keep collecting real simulated
   data while fitting dynamics and improving the policy. Evaluate coverage and
   held-out scope separately; expand based on measured behavior.
6. **Deployment qualification later:** simulator training does not settle the
   hardware contract. Avoid treating physical calibration as already measured.

Do not require a fully trained tracker as a prerequisite to admitting every
reference; that would create a circular validation workflow. Kinematic and
geometric screening precedes learning. Closed-loop physical tracking then
provides separate evidence, including evidence for refining the dataset.
Our earlier recommendation for complete dynamic qualification before training
was stronger than the paper's protocol. Collision, orientation and actuator
checks are useful E1 engineering additions; they should not be represented as
requirements that the paper itself establishes.

This review describes the original baseline. The subsequent authorized workflow
correction stopped that baseline at its published generation 1600 and preserved
its data, logs and checkpoints. The replacement workflow is implemented in
`learning_e1_training` and `scripts/e1_qualified_training.mbtx`:

- Independent URDF/MJCF/recorded-pose and native FK checks precede admission.
  The simulator kinematics agree to numerical precision; vendor `dance1` has
  inconsistent source body records and is quarantined.
- All four vendor candidates and the pinned 40-file G1 panel are accounted for.
  The new fitter handles anatomical offsets, joint and velocity bounds using
  a bounded solve, bounded floating-base orientation, stance-foot support from
  actual sole geometry, native collision penalties, and a line search. Fixed
  complete-motion screening admits references before any learned-policy test.
- Normal training checks the admission manifest, model/runtime identities and
  each accepted motion/report hash before GPU allocation. An explicit diagnostic
  flag is required for the old unqualified software lifecycle fixtures.
- The new nominal configuration has 128 environments, UTD 0.1, WM batch 256 and
  actor batch 512: 2 world windows and 12.8 imagined steps per new physical
  transition, matching the paper's nominal ratios at a smaller scale. Actual
  cumulative exposure includes warm-up and actor-readiness collection. The
  14,000-iteration cosine schedule matches the planned 14,000-iteration budget.
- The qualified gate enables actor/critic updates immediately and evaluates
  every admitted training and validation motion in full. Production retains
  500 world-only iterations and repeats that full-catalog evaluation every
  500 iterations and at the end. Early termination retains each full-motion
  denominator. Excluded candidates remain outside that evaluation denominator
  and are reported separately, so coverage is explicit.

These are simulator curriculum and workflow qualifications. They do not imply
that all G1 wrist orientations can be preserved by E1's smaller arm chain,
that closed-loop tracking has converged, or that the physical robot has been
calibrated. The per-motion reports retain the source-preservation losses and
any declared tempo changes.

## Executed correction, 11 November 2026

The replacement run started on Spark 179 at **02:05:47 Beijing time**, in
`moonrobo-e1-qualified-20261111`. Its first immutable checkpoint, generation
100, was saved and its checkpoint-manifest digest verified. The status bridge
and E1 showcase now follow this run. The old baseline and its generation 1600
remain preserved.

Spark 178 completed all **44 candidate decisions**: **6 admitted, 38 excluded**.
The admitted catalog has 51,385 training frames and 1,210 validation frames at
50 Hz. Every retained clip is complete; the G1 candidates retain their source
tempo. The validation boxing clip has an explicitly recorded 3.1486× duration
scale to accommodate its source joint speeds.

| Motion | Split | Frames | Body RMS | Maximum stance-position error |
| --- | --- | ---: | ---: | ---: |
| `vendor-0_boxing` | train | 200 | 3.92 cm | 1.36 cm |
| `g1-jumps1_subject5` | train | 12,222 | 4.55 cm | 0.97 cm |
| `g1-run2_subject4` | train | 12,241 | 4.70 cm | 1.68 cm |
| `g1-sprint1_subject2` | train | 13,656 | 5.02 cm | 0.73 cm |
| `g1-walk1_subject1` | train | 13,066 | 4.44 cm | 0.77 cm |
| `vendor-02_boxing` | validation | 1,210 | 2.64 cm | 2.16 cm |

All admitted references have zero joint-range and joint-speed violations within
numerical tolerance and pass the versioned complete-motion geometry/contact
rules. Admission is conservative: only 6/44 candidates pass. Full G1 wrist
orientation preservation is not established; the fitter reports those losses.
This is a small simulator curriculum, rather than a full BONES benchmark.

**11/11 E1 tests and 20/20 scoped G1 regressions passed.** The qualified gate
used the production architecture and data ratios with actor/critic warm-up
disabled for two iterations: 20 world updates, 2 actor updates, 40 critic
updates, and 32,768 imagined transitions. Both checkpoints evaluated all five
training motions and the validation motion from frame zero. Protocol coverage
was complete; early termination retained each full-duration denominator.
At gate iteration 2, completion was **0/5 training and 0/1 validation**. The
equal-motion mean normalized returns were 0.029778 and 0.010484, respectively.
Those are early policy baselines, not convergence evidence.

The fresh run uses 128 physical environments, WM batch 256, actor batch 512,
W8/H32, UTD 0.1, a 14,000-iteration cosine decay, and 500 world-only iterations.
It saves every 100 iterations and evaluates the entire admitted train and
validation catalogs every 500 iterations and at the end. The first scheduled
evaluation at checkpoint **500** completed with full protocol coverage across
all six motions. Completion remained **0/6** at the end of world-only warm-up;
mean normalized returns were 0.029698 for training and 0.010473 for validation.
At iteration **520**, production actor/critic updates were active, reporting
16,384 imagined steps and 20 critic updates per iteration, with zero extra
actor-readiness collection steps. No OOM was reported. Its observed container
footprint was approximately 55 GiB under a 100 GiB cap. The eager estimate is
not a measurement of the full replicated MuJoCo/container footprint; use the
observed memory figure when assessing this configuration.

Compact evidence lives in `output/e1-qualified-workflow-20261111/`:
`publication.json`, `admission.json`, all 43 retarget reports, `model-validation.json`,
`budget.json`, `gate-summary.json`, complete gate evaluation reports, native test
logs, `launch.json`, `checkpoint-100.json`, and the dated status snapshot.
`checkpoint-500.json` and both `evaluation-500-*.json` reports record the first
scheduled production evaluation.
Large references and checkpoints remain on the Sparks.

Key identities:

- Dataset: `182c866d79caf81869389e700258c34c7cbd788d826df9b77e7fe62b78881f68`.
- Admission: `04169799c66f1e68bafbde11f02bbc3e3c73d2616692e5b6873bf5865021da8b`.
- Data-generator executable: `326c9eec06b72030e4a58d438bfd5904b3fdb66ce56465d3876d6f96a93adf8d`.
- Training executable: `d90bc9293c67bb8fdc818ca47a96296a0f1eaad507f968f1ff654ab7c3d449ee`.
- Training configuration: `6cb1beb5acd20540381c24c9e1e6829306b0bda7d3842eedfbfd854819bb6327`.
