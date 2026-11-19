# Temporal PPO numerical verification

Parallel implementation of `providers/motion_learning/temporal_ppo_verification.py`.
The Python file is retained. Run the native CLI with `--study`, `--incoming`,
`--library`, `--scene` and `--output`. It loads `policy/report.json` and its
hash-verified gzip JSONL records, and automatically loads legacy `actor-seed-N.pt`
numeric checkpoints or native `.moon.json` / `.json` / `.actor.json` checkpoints.
The current `.moon.json` artifact takes precedence over preserved Torch
companions. Incoming model ancestry is mandatory; missing `model_ref` fails
instead of skipping the compiled-model identity check. Regression test sources
cover filename precedence and missing ancestry, but were not executed.

The driver checks iteration/reset order, case order and coverage, train family and
model identities, episode uniqueness and continuity, terminal boundaries, causal
previous actions, latent-to-clipped-setpoint equality, objective rewards, finite
physical MC returns, soft continuation, discounted survival visitation, per-update
history counts and full training totals. It emits the original numerical
verification report schema, including action error and latent saturation/sensitivity.

Legacy archives use explicit Float32 rounding at arithmetic boundaries; native
JSON actors use native f64 equations. Applied actions and previous actions retain
the original exact-equality requirement; reward/return/continuation/visitation
retain `atol=1e-5, rtol=1e-6`. No tolerance is widened to hide numeric differences.
Elementary `tanh`/`exp` and reduction implementation differences from Torch can
therefore cause a legacy audit to fail; exact cross-library parity remains for the
deferred execution/comparison session. The driver does not claim verification
success before it runs.

Loading MuJoCo supplies the actual compiled layout/control bounds and declared
reference schedule. This audit calls no simulator reset or step, and performs no
training or learned transition inference. Only native typechecking was performed
during migration; no audit/test/simulation was executed.
