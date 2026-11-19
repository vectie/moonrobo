# Balance and temporal test-source migration

All twelve original `providers/motion_learning/test_*.py` files in this assignment
remain unchanged. The MoonBit tests below are additional source code. **No test,
training step, simulation, benchmark or parity experiment was executed while
writing them.** `moon check --target native` checks their types without running
their bodies. Root coordination owns the final repository-wide `moon info` and
`moon fmt` pass.

Paths in this table are relative to `src/`. Test names follow the original
contract rather than relying on a shared smoke test.

| Original source and cases | MoonBit test sources | Preserved assertions and boundaries |
|---|---|---|
| `test_balance_features.py`: static geometry/native FK and derivative check | `learning_balance/physics/features_contract_test.mbt`, `learning_balance/features_gradient_contract_test.mbt` | 32 random free-root poses; joint anchor/reference offset and fixed descendants; native COM, foot positions and observation projection with original `1e-13 + 1e-12*abs(expected)` tolerance. Actual reverse-mode FK compared against independent central differences (`eps=1e-6`, `atol=1e-6`, `rtol=1e-4`). MoonBit and NumPy RNG streams differ. |
| Same source: fixed-world-error transport; online/offline prefix; full constant-memory observer/reset | `learning_balance/balance_test.mbt`, `features_test.mbt`, `features_gradient_contract_test.mbt`, `history_contract_wbtest.mbt` | Both gyro methods at original `2e-15` zero-velocity tolerance, body-difference counterexample, gravity correction at `1e-14`, finite/full observers at original absolute+relative tolerance, prefix equality and fresh-reset zero velocity; exactly two retained full-observer raw frames. AD gradients are finite for the past, nonzero somewhere, exactly zero after the selected frame. The AD graph is the production graph shared with `learning_reference`. |
| `test_balance_teacher.py`: support compensation | `learning_balance/teacher_contract_test.mbt`, `learning_balance/physics/features_contract_test.mbt` | Independent support kernel and actual MuJoCo Jacobian/bias/gravity; first six generalized torques below `1e-10`, nonzero hinge torque. The fixture is explicit XML with five named feedback actuators. Exact original `qfrc_applied` array nonmutation, plus state and actuator-force nonmutation, are asserted through read-only native accessors. |
| Same source: tilt/COM signs and goal preservation; residual/actuator bounds and episode reset | `learning_balance/teacher_contract_test.mbt` | Original five-channel signs, waist share, unchanged goal, actuator clipping, residual clipping and fresh teacher EMA. Pure feedback accepts measured geometry explicitly instead of mutating a Python `SimpleNamespace`. |
| `test_balance_intervention.py`: window length/reset; group substitution | `learning_balance/intervention_contract_test.mbt`, `learning_balance/intervention/native_contract_test.mbt` | N frames mean N-1 differences; 35-step trace; 50-frame/full equality; 10-frame EMA; one-frame zero velocity; fresh zero memory; group indices and nonmutation. Native window test measures real COM with a checked-in model; pure test preserves the original analytic error sequence independently. |
| `test_learned_balance.py`: censored planted-law recovery | `learning_balance/learned_contract_test.mbt` | 2,000 examples; original planted 4x4 law, residual and actuator censoring, uncensored counts, coefficient and prediction `2e-7` thresholds. Samples use native RNG17 rather than claiming NumPy seed equivalence. |
| `test_sustained_balance.py`: pose/rate and pre-damping waist fit | `learning_balance/sustained_contract_test.mbt` | 4,000 examples; original ankle/waist laws, censoring and damping order; coefficient tolerances `2e-4`/`2e-6`, predictions `3e-6`, reduced-feature MSE above `1e-4`. Native RNG23 differs from NumPy. |
| `test_balance_export.py`: recorded next-state contact reconstruction | `learning_balance/physics/export_contract_test.mbt` | Native contact scene; captured and reconstructed replay fields within `1e-14`, positive contacts. This original source contains one reconstruction test, rather than a six-head registry-export test. |
| `test_full_body_reference.py`: nonzero-origin replay; next-frame/masked preview; yaw/XY invariance; policy interface and missing/duplicate quality cells | `learning_balance/physics/reference_g1_contract_test.mbt`, `physics/reference_contract_test.mbt`, `reference_test.mbt`, `balance_test.mbt` | The original external G1 scene contract is authored: origin7, remaining source controls, no failure, state error below `1e-10`, next-frame goals, exact padded masks, controls do not change goals, observation93/action29/future10 dimensions, exact policy-vs-position transition equality, yaw/XY tolerance `3e-15 + 1e-12*abs(expected)`, missing/duplicate-cell rejection. A separate checked-in toy scene exercises the same replay semantics without downloading Menagerie. |
| `test_temporal_actor.py`: causal history and gap restart; zero adapter/native checkpoint; constant-goal imagined legacy recurrence and AD; declared preview times | `learning_temporal/temporal_test.mbt`, `training_test.mbt`, `actor_contract_test.mbt` | All four original contracts have explicit assertions. Native temporal save/reload preserves actions; the actual base loader rejects the temporal kind. Independently coded recurrence matches imagined state/reward/continuation; finite nonzero actor gradients; changed future goals change objective. Checkpoint tests write under `target/migration-test-artifacts/` only when later executed. |
| `test_temporal_value.py`: task tail/translation/paired checkpoint; predicted history/future/remaining time; physical task cap | `learning_temporal/value_contract_test.mbt`, `learning_temporal/physics/value_contract_test.mbt` | Remaining0 and fallen-state masks; XY invariance; history/goal sensitivity; embedded paired checkpoint reload; H10 predicted-history tail, future command phase and `.94` remaining time; differentiable actor and frozen dynamics/value parameters; terminal reward included with no post-cap tail; held-out value labels rejected. |
| `test_temporal_ppo.py`: discounted weighted score identity; stochastic physical history/mean/setpoints | `learning_temporal/ppo_contract_test.mbt`, `training_test.mbt`, `physics/ppo_contract_test.mbt` | Enumerated two-step expected-return gradient vs detached-probability PPO score with original `1e-7 + 1e-6*abs(expected)` tolerance; clipping plateau; actual native latent samples, Gaussian logprobs, behavior mean reconstruction, action inversion, previous executed-action history and final truncation. |
| `test_temporal_probe.py`: dynamic restoration/history/phase/full end; per-origin returns and frozen-model Adam | `learning_temporal/physics/probe_contract_test.mbt`, `probe_contract_test.mbt` | Actual native origins0/2/4, command phase and integration snapshots; remaining rollout/state/action agreement at `1e-12`; physical calls restore runtime state and integration; older causal history changes actions. Two-origin imagined returns average correctly and one real Adam direction improves the same frozen toy model. Test captures origins through public native callbacks; the separate study driver's collection entry point is not called directly by this package's regression test. |
| `test_temporal_disturbance.py`: noisy student controls vs labels and independent teacher state | `learning_temporal/physics/disturbance_contract_test.mbt` | Two separately constructed teachers receive10 calls each; targets remain goal+.2; executed noisy student actions remain distinct; exact previous-action reconstruction and zero initial previous action; validation collection rejected. Optional `collect_labeled(..., teacher_factory=...)` preserves the original injectable-factory test boundary; normal native-teacher callers remain unchanged. |

## External requirements and outstanding execution

Final local typecheck: all five affected packages (`learning_balance`,
`learning_balance/physics`, `learning_balance/intervention`, `learning_temporal`,
`learning_temporal/physics`) passed `moon check <package> --target native
--warn-list '-a'`. Test bodies were not executed. These source files are frozen
for the root coordinator's final interface/format/manifest pass.

- Native tests require `MOONROBO_MUJOCO_LIBRARY` pointing to the matching MuJoCo
  shared library. Missing configuration fails with a diagnostic; there is no
  silent skip. XML fixture files under `learning_balance/physics/testdata/` and
  `learning_temporal/physics/testdata/` are source artifacts, not generated runs.
- The exact G1 test requires the original
  `target/mujoco_menagerie/unitree_g1/scene_mjx.xml` and its mesh assets, or an
  explicit `MOONROBO_G1_SCENE` override providing that same model contract. The
  model is not downloaded or simulated during translation. This is a real
  external asset boundary, separate from the checked-in toy replay tests.
- The original probe test also calls its Python study's `collect_origins` and
  checks a held-out collection rejection. The translated physical restoration
  regression constructs the same origins through the native trace callback;
  held-out rejection is independently asserted on train-only point/label
  collectors. Its study-specific collection validation is not directly exercised
  by this package's tests.
- Tests target the translated MoonBit algorithms and native MuJoCo boundary.
  They do not invoke Python, PyTorch, NumPy or a Python subprocess. Historical
  Torch/NumPy float32 outputs and exact RNG sample identity require later paired
  comparison. Authoring an assertion or passing a typecheck does not establish
  that assertion's runtime result.
