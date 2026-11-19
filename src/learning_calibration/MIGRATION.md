# Temporal calibration and verification

`noise.mbt` implements `temporal_ppo_noise.py` end to end: unchanged incoming actors; train-only case checks; fixed reset seed per parent; a separate reproducible per-case latent-noise stream restarted for each amplitude; actual temporal histories/goals; true MuJoCo episode collection; setpoint-noise RMS and mean-latent saturation; gzip datasets with source actor SHA; original report schema and scope.

```console
moon run src/learning_calibration/cli -- noise MUJOCO_LIBRARY SCENE CONFIG COLLECTION POLICIES OUTPUT
```

The policies directory may contain native `actor-seed-N.moon.json` or legacy `actor-seed-N.pt` files. The restricted numeric Torch importer handles supported legacy state dictionaries without Python execution.

Differences: scalar/network arithmetic is Double, and xorshift/Box–Muller noise does not reproduce Torch's seeded samples. Coupling across amplitudes and independence across case fall times are preserved. Output trial identities are updated together with suffixed episode identities. The original script suffixes the episode identity while leaving the trial identity unchanged; this implementation keeps the two linked. The report explicitly names its RNG. No physics, calibration, tests or checkpoint loading were executed during migration; native type checking is the current evidence.

`verification/` separately owns the translation of `temporal_ppo_verification.py`; see its package documentation for coverage and deferred execution.
