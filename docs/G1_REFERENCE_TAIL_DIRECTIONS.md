# G1 Reference Critic-Tail Direction Comparison

Updated: 2026-10-23. Status: controlled physical probes completed. Removing
the tested critic tail improves local directions in both model variants;
every physical trial still falls. This supports a training ablation, not a
qualified controller or successful learning-efficiency result.

The [root integration study](G1_REFERENCE_ROOT_INTEGRATION.md) found critic-tail
derivatives opposing useful prefix derivatives in two seeds. This follow-up
tests new prefix-only parameter directions in actual physics, instead of
assuming that the decomposition alone identifies a better algorithm.

## Comparison

The [pre-run charter](../examples/learning/g1-reference-tail-directions.json)
fixes both models (free residual / root-integrated), all three seeds, the same
incoming actor, known reset clips, perturbation amplitudes and reference reward.
All six dynamics checkpoints and the seed-specific common-data critics come
from the preceding study. No model, value or actor optimizer is run here.

The existing with-tail directions optimize a discounted H32 prefix plus the
physical-return critic tail. The new directions differentiate only that H32
prefix. Each is computed at the identical incoming actor over all nine
first-collection episode starts, then calibrated to raw-logit RMS response on
the same seed's complete noisy training collection. Physical probes evaluate
both signs at RMS 0.001 and 0.005 on stand, pose-offset and joint-sines at
origin zero, friction 1. All remaining-reference rollouts continue through
fall or the original thirty-second reference end.

The 75 original baseline/with-tail records are referenced without copying or
recollecting them. Only the 72 prefix-only episodes are new. Reports preserve
the old checkpoint/direction/archive hashes and separately count new physics.
The same saved actor plus parameter vector and coefficient reconstruct every
probe. Frozen model tensors stay unchanged and receive no gradients.

## Physical result

At **each** of the two fixed amplitudes, positive directions have these results:

| Model | Direction objective | Mean full return improves, seeds / 3 | H32 physical prefix improves, clips / 9 | Full physical return improves, clips / 9 |
| --- | --- | --- | --- | --- |
| Free residual | With critic tail | 1 | 1 | 3 |
| Free residual | Prefix only | 3 | 9 | 9 |
| Root-integrated | With critic tail | 0 | 0 | 0 |
| Root-integrated | Prefix only | 3 | 9 | 8 |

The nine cells are three model-training seeds × three known reference clips,
not nine independent motion families. Repeated amplitude/seed conditions share
the deterministic initial policy and reset states. No significance or unseen
motion generalization claim is made.

Full physical return changes from the shared baseline at raw-logit RMS 0.005:

| Model | Seed | With-tail direction | Prefix-only direction |
| --- | --- | --- | --- |
| Free | 0 | −0.09054 | +0.10112 |
| Free | 1 | −0.07435 | +0.16361 |
| Free | 2 | +0.01872 | +0.07812 |
| Integrated | 0 | −0.10041 | +0.12970 |
| Integrated | 1 | −0.03292 | +0.13076 |
| Integrated | 2 | −0.04243 | +0.01524 |

The integrated prefix-only arm's seed-2 standing clip slightly worsens full
return at both amplitudes, despite improving its prefix and the three-clip
mean. Every one of the 147 paired episodes still falls, including all 72 new
ones. These are useful small local directions; there is no completed policy
training, selected checkpoint, fixed 27-cell quality pass or speedup result.

The intervention concerns this critic, fitted on the limited common noisy
collection. It does not show that critics or longer objectives are generally
harmful. Prefix-only optimization changes the training objective and can
favor early tracking at the expense of later behavior. Some finite-step model
predictions also disagree with actual return, notably free seed 2, even though
the physical direction improves. The gradient-generation objective spans nine
training resets while the physical diagnostic covers the predeclared three.

## Evidence and next work

New collection is **72 episodes / 25,176 transitions**. The complete paired
report contains **147 episodes / 51,393 transitions**, including the previously
validated 75 / 26,217. All paired records pass numerical reconstruction and
the native MotionDataset reader. Maximum logit error is 2.05e-8, applied-action
error 0.00001631 rad and causal feature error 1.44e-6; reward and discounted
return reconstruction match. Archives remain float32, with original scalar
quality metrics from float64 MuJoCo.

A regression check confirms that omitting the tail preserves imagined
transition counts, removes a known continuation value, and retains zero
continuation at the finite reference end. All 62 numerical tests pass. MoonBit
orchestrates collection and native verification; training numerics stay in
the existing external provider.

- [Verified paired report](../output/research/g1-reference-tail-directions.json)
- [Numerical experiment](../providers/motion_learning/reference_tail_directions.py)
- [Probe orchestration](../scripts/probe_g1_reference_tail.mbtx)
- [Native verification](../scripts/report_g1_reference_root.mbtx)

Artifacts live in `target/learning/g1-reference-tail-directions`, with frozen
sources/charter, incoming checkpoint, six new parameter vectors and 72 new
compressed physical archives. Reused arrays/models remain in the preceding
study. Source report SHA-256:
`bcb42a3bbe0aac501dc1c7937aab1bafe7dbe63e04cb979b5914dd28a14b6ba7`.
Provider time is 100.57 CPU seconds, excluding native verification and prior
collection/model/value fitting. These artifacts are not yet registered in
MoonData.

Next compare actual with-tail/prefix-only training under a newly frozen common
budget, preserving the original 27-cell quality target. Include collection,
refitting and full-reference evaluation; local probe success cannot substitute
for that learning result. The [complete phase plan](SUPERMIMIC_PHASE_PLAN.md),
larger motion coverage, workbench, matched successful cost-to-target and E1
qualification remain unfinished.

The subsequent [actual training comparison](G1_REFERENCE_TAIL_TRAINING.md)
now runs both objectives with mixed reset phases and a common local step cap.
All 603 new episodes validate natively. Prefix-only does not consistently
improve final survival, and every one of the six policies still falls in all
27 qualification cells. The local direction result is retained without being
promoted to a successful training claim.
