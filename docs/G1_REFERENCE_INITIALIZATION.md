# Full-Body Reference Encoder And Control Initialization

Updated: 2026-10-23. Three independently fitted reference encoders now pass every
cell of the fixed local full-body tracking gate: 81 trials, zero falls. They
share a previously learned observation-only balance law. This supplies a working
reference-conditioned initializer, not model-based/PPO learning efficiency,
unseen-motion coverage, a complete platform release or hardware qualification.

## Reference And Actor

The [reference slice](G1_FULL_BODY_REFERENCE.md) provides nine successful physics
clips, all from known training families. Each is thirty seconds. At each action
the actor receives actual observation history H10, the current 338-channel
reference frame, future reference frames F10 and their validity mask. Current
and future references are commands; they contain no source controls or actual
future robot observations. At a nonzero origin the physical state is restored
once and both observation filters reset; later states evolve normally.

[`reference_actor.py`](../providers/motion_learning/reference_actor.py) implements:

- A reference encoder with widths 128/64/32 and tanh latent32, consuming the
  current frame plus the ten-frame preview/mask.
- An observation encoder from H10 × 93 to 64/64, followed by a 128/29 decoder
  using the reference latent and observed features.
- Frozen learned ankle feedback on actual-minus-reference COM/support error,
  causal velocity, joint speed, projected-gravity tilt and angular rate.

The feedback slopes come from the prior pose/rate v2 fit, not manually copied
teacher gains. Four learned bias terms cancel in the difference; twenty slopes
remain. Its compiled static kinematics and coefficients embed in the new
checkpoint. The old temporal parent and waist controller are not used. Actual
and reference filters each retain full episode-local causal memory. No simulator
COM, contacts or actual global root pose enters inference.

Action is current-reference joint position plus a learned 0.6 × tanh residual
and relative ankle correction. The latter clips to ±0.45 rad; the combined
residual clips to ±0.6 rad before physical actuator bounds. The maximum label
residual is 0.480893 rad, inside that declared range. These are position-servo
setpoints, not direct posture commands or torques.

The new checkpoint format is `moonrobo.g1-reference-actor.v1`, with named
architecture, normalizers, static kinematics, filter/goal/action semantics,
provenance and `physical_execution_allowed: false`. There is no trained critic.
`ReferenceRunner` maintains real observation histories and both causal filters;
`ReferenceActor.forward` accepts their explicit features for later differentiable
learning. A future critic/imagination loop must preserve that state, rather than
assuming H10 alone is the full controller state.

## Two Fixed-Budget Supervised Studies

All 13,500 source states train the encoder/decoder. Recorded controls are labels
only. Normalizers use these train points; every scale has a numeric floor of
0.05 in its channel's declared unit. Each seed uses 1000 Adam updates, batch256,
learning rate 0.001, width/latent/history/preview above, and the same inherited
feedback. Final update1000 is evaluated without seed/checkpoint selection.

The [joint-input config](../examples/learning/g1-reference-initialization.json)
fits both reference and observation paths. It has low source-action error, yet
fails the physical gate for every seed. The subsequent
[reference-only initialization config](../examples/learning/g1-reference-feedforward-initialization.json)
changes only the supervised observation path: zero the decoder's 64 observation
input columns and mask their gradients during fitting. Actual observations still
drive the relative balance feedback. The temporary hook is removed before saving;
the saved zero columns can receive gradients in later shared RL. All architecture,
data, update budgets, output bounds and quality limits remain the same.

| Supervised path | Seed | Source action RMSE (rad) | Falls / 27 | Joint RMSE (rad) | Body RMSE (m) | Quality |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Reference + learned observation | 0 | 0.001065 | 16 | 0.029376 | 0.096671 | Fail |
| Reference + learned observation | 1 | 0.001014 | 11 | 0.029356 | 0.077132 | Fail |
| Reference + learned observation | 2 | 0.001154 | 13 | 0.023999 | 0.077484 | Fail |
| Reference only + fixed relative feedback | 0 | 0.002350 | 0 | 0.002057 | 0.001016 | Pass |
| Reference only + fixed relative feedback | 1 | 0.002422 | 0 | 0.001978 | 0.001027 | Pass |
| Reference only + fixed relative feedback | 2 | 0.002492 | 0 | 0.002174 | 0.001075 | Pass |

Every passing trial individually meets joint RMSE ≤0.03 rad, body/root position
RMSE ≤0.05 m and root-angle RMSE ≤0.1 rad, with complete duration and no falls.
The three passing root-position RMSEs are 0.000468/0.000445/0.000519 m and root-angle
RMSEs 0.002909/0.003374/0.003095 rad. Origins 0/10/20 seconds run their remaining
30/20/10 seconds, respectively: 540 seconds per policy, mean20 seconds, not
27 thirty-second trials. Families, friction variants and origins are correlated.

Both studies separately rerun the same zero-output initialization baseline:
27/27 falls, mean survival5.62815 seconds, joint RMSE0.053334 rad. The learned
residual is zero; relative feedback remains active. This differs from the older
next-joint-position baseline and does not isolate the feedback alone. The two
baseline reruns are the same conditions, not 54 independent conditions.

The improved closed-loop result despite worse source-label error supports
initializing the reference control mapping without an unconstrained learned
observation shortcut on these data. It does not establish that proprioception
is harmful generally or that the paper's decoder design is unnecessary.
Training-family physics selects the next development direction; no untouched
release test or unseen motion is claimed. Three new neural fits are independent
training seeds, while their normalizers, corpus and fixed feedback are shared.

## Evidence And Verification

Reports retain both outcomes:

- [Joint-input initialization](../output/research/g1-reference-initialization-study.json):
  108 physical episodes, 57,365 actual transitions; all native-validated.
- [Reference-only initialization](../output/research/g1-reference-feedforward-initialization-study.json):
  108 physical episodes, 88,598 actual transitions; all native-validated.

Each NPZ preserves actual state/observation/control/next state/reward and terminal
flags. A pinned reference ID/hash/origin reconstructs the complete numeric goal,
avoiding redundant reference vectors in every trajectory artifact. Nothing after
a fall is fabricated. Source/provider/checkpoint hashes and the pre-training
quality/configuration charter are retained in each study directory.

The independent export verifier decodes saved arrays, checks continuity and
recomputes body/root position and rotation errors using MuJoCo kinematics. It
does not rerun a policy or overwrite subsequent physical states. Maximum
reconstructed metric difference is 1.39e-17; native code independently recomputes
joint error to within 1.11e-16 rad across both studies. All source/current/full
goal vectors pass the unchanged MotionDataset reader. The passing checkpoints'
observation-decoder columns are independently verified zero. Unit tests verify
input/runner alignment, relative feedback, checkpoint equality, causal features,
source-label exclusion from goals and trainable observation columns after load.
All 55 numerical tests and five native motion-data tests pass. `moon info`
reports no errors and no new public MoonBit API; existing toolchain warnings
remain. The new orchestration/report scripts are checked and formatted.

Passing checkpoints are under
`target/learning/g1-reference-feedforward-initialization/policy/actor-seed-{0,1,2}.pt`:

| Seed | SHA-256 |
| --- | --- |
| 0 | `8f3447b748ec38ab125fdc63549d99bb4456107d48c3837a3687cf01b5a5a57a` |
| 1 | `db9f5aba3f20021b0378a1786a03c6f5f608a0668e813593f79897ab5be07d1d` |
| 2 | `092a7c25a8a18a30773fce14fbf019e6679b16b7d0fe098d5044ab8a2ed6dee4` |

The first study measures 8.18 seconds of optimizer work across its three fits;
the second 8.34 seconds. Reported intervals including fitting, physical evaluation
and serialization after reference/model setup are167.42/256.62 seconds. They
exclude prior teacher/feedback/reference development and native verification;
some verification runs overlap other work. They are not an isolated hardware
throughput or matched learning-efficiency comparison.

## Run And Next Integration

```sh
moon run --target native scripts/fit_g1_reference_initialization.mbtx /Users/kq/Workspace/moonrobo /Users/kq/Workspace/moonrobo/target/learning/g1-full-body-reference /Users/kq/Workspace/moonrobo/target/learning/g1-sustained-balance/policy/actor-pose45-ankle-seed-0.pt /Users/kq/Workspace/moonrobo/target/learning/g1-reference-initialization-new
moon run --target native scripts/fit_g1_reference_initialization.mbtx /Users/kq/Workspace/moonrobo /Users/kq/Workspace/moonrobo/target/learning/g1-full-body-reference /Users/kq/Workspace/moonrobo/target/learning/g1-sustained-balance/policy/actor-pose45-ankle-seed-0.pt /Users/kq/Workspace/moonrobo/target/learning/g1-reference-feedforward-initialization-new /Users/kq/Workspace/moonrobo/examples/learning/g1-reference-feedforward-initialization.json
moon build cmd/motion_dataset --target native
moon run --target native scripts/report_g1_reference_initialization.mbtx /Users/kq/Workspace/moonrobo /Users/kq/Workspace/moonrobo/target/learning/g1-reference-feedforward-initialization /Users/kq/Workspace/moonrobo/output/research/g1-reference-feedforward-initialization-study.json
```

The subsequent [reference platform integration](G1_REFERENCE_PLATFORM.md) now
registers both groups under their own producer format. It seals the reference
clips, all physical arrays, quality/verification/configuration evidence and
checkpoints. The actual cockpit distinguishes origins/remainders and overlays
planned root motion with physical outcomes. Full-body 3D animation and
world-model comparison remain open; existing experiments remain intact.

The supervised initializer already passes the fixed local target. Refining it
with either world-model or PPO starts at zero incremental cost-to-that-target;
it cannot demonstrate a learning speedup. A useful next comparison can start
both methods from the same nonpassing zero-output actor, retain this supervised
method as a separately costed baseline, and freeze all input/feedback priors,
reference-action-label access, policy/critic memory, rewards, noise, resets and
budgets before training. Do not silently feed source controls to one method or
change the quality target after seeing comparison results. Bigger motions,
unseen families, E1 adaptation and physical qualification remain separate work.
