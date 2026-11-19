# Reference gradient-route drivers

Parallel native implementations of `providers/motion_learning/reference_final_route_training.py`, `reference_gradient_route.py` and `reference_tail_directions.py`. Python remains unchanged. All three drivers, the independent actor-update verifier and the fork test source have passed `moon check`; no tests, training, reconstruction, native physics experiment or old-checkpoint comparisons were executed during migration.

Each driver expects `OUTPUT/config.json` and the same prior study/report/manifest/archive hierarchy as its Python source. Source and output paths are canonicalized, original report/checkpoint/manifest hashes are checked, and inherited physical records point to their actual source paths.

```sh
moon run src/learning_reference_routes/cmd -- final DIAGNOSTIC_STUDY MUJOCO_LIBRARY SCENE OUTPUT
moon run src/learning_reference_routes/cmd -- gradient DIAGNOSTIC_STUDY MUJOCO_LIBRARY SCENE OUTPUT
moon run src/learning_reference_routes/cmd -- tail MODEL_STUDY MUJOCO_LIBRARY SCENE OUTPUT
moon run src/learning_reference_routes/cmd -- verify FINAL_ROUTE_STUDY MUJOCO_LIBRARY SCENE
```

`final` restores every archived collection and fixed cycle model, reproduces the original actor operations with retained Adam moments and sampling state, and requires **exact original actor tensor and origin-draw equality at every cycle** before it may proceed. At the declared final intervention it forks actor, optimizer and sampler without aliasing; checks identical full/stopped forward objectives; completes/reuses the full route; runs the stopped-input route with matched draws; then collects the full physical quality suite. It saves the stopped actor and explicit actor-only optimizer/sampler state paired to the frozen model/source hashes. The `verify` command independently checks scene/version, artifact bytes, actor/model/source/config pairing, optimizer shapes/moments, exact sampler restore and recorded digests, and writes `actor-update-state-verification.json`. This proves only the declared fixed-model actor update state, not a full alternation-worker restart.

`gradient` differentiates full and stopped policy-input routes on matched archived origins, requires exactly equal forward objective/active counts and nonzero finite gradients, measures their cosine/projections, saves normalized named parameter directions, calibrates each requested sign/amplitude to the original strict fixed-input logit-RMS tolerance, and measures actual physical prefix/full return changes against inherited same-actor baselines. Frozen actor/model restoration is checked afterward.

`tail` inherits the prior with-tail results and records, differentiates a new zero-tail H32 objective from the same fixed base actor/model, calibrates the prefix direction on the shared training inputs, saves it, and collects the original signed/amplitude physical comparisons. It checks model training-record identity, all original input hashes and unchanged model parameters.

Sampling uses the portable MoonBit generator by default. An explicit `torch_rng_adapter` path in the charter/config loads the optional real ATen CPU RNG plugin for actual Torch `randint` call shapes/order and restorable generator bytes. It does not silently emulate Torch seed laws. Adam snapshots preserve native Double moments exactly. The old Python actor-update `.pt` optimizer artifact is not automatically converted by the independent native verifier; it is explicitly rejected, while original actor/model/direction `.pt` inputs use the restricted safe imports.

Float64 arithmetic and dense reduction order differ from original Torch Float32. **The exact reconstruction/origin/forward gates have not been relaxed.** A legacy reconstruction that differs must stop instead of producing a verification or reusing final evaluations as matched. Optional ATen sampling alone is not a claim of Float32 numerical equivalence. The legacy bit-identical reconstruction has not been exercised in this session. Output checkpoints/directions/update states and report schemas are native/versioned JSON. Some original per-stage timing/provider hash fields are omitted. All outputs remain simulation diagnostics with no release or hardware authority.

`fork_wbtest.mbt` now contains two pending regressions: matched Adam/sampler
updates with explicit parameter/moment/RNG mutation isolation, and a warmed
actual ReferenceActor fork using `fork_actor_optimizer` with the same contracts.
Both were type checked, not run. The original case mapping is in
`../learning_reference/TEST_MIGRATION.md`.
