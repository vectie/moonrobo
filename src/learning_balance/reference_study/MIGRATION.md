# Full-body reference study

Parallel native translation of `providers/motion_learning/full_body_reference_study.py`.
The Python source is retained. This package uses real MuJoCo, the native balance
teacher and the native full-body replay implementation; it never launches Python.

The driver collects training-family source episodes, captures each physical state
and final state (integration, body poses, quaternions, contacts, timestamps and
actual `mj_objectVelocity` world velocities), persists source evidence, rejects a
failed source as a successful reference, writes numeric NPZ clips, reads back the
hashed bytes, replays source-setpoint/joint-position modes from requested origins,
and writes gzip JSONL evidence, a hash-linked manifest and frame-weighted RMSE
study report. Source controls stay outside reference goals. No training updates or
release/hardware claims are added.

```text
moon run src/learning_balance/reference_study/cmd --target native -- --library /path/libmujoco.dylib --scene /path/scene.xml --config /path/study.json --collection /path/train-collection.json --teacher-study /path/native-teacher-study --output /path/new-study
```

The teacher JSON's `provider_sha256` must match the native teacher wrapper source
(`src/learning_balance/physics/teacher.mbt` by default). The separate kernel source
hash is also recorded. The CLI accepts `--teacher-provider-source`,
`--teacher-kernel-source`, `--provider-source` and `--reference-provider-source`
overrides when running outside the repository. An old Python provider hash is not
silently accepted as the hash of a native implementation.

Compatibility differences: NPZ uses NumPy-compatible stored numeric members rather
than compressed members; contacts are represented as f64 numeric values. The
portable RNG is different from NumPy's generator. Native source/package hashes and
`source_language: moonbit` distinguish the evidence. Full physical and numerical
parity is pending the deferred comparison run.

Validation performed: native `moon check` of driver/CLI and dependency APIs only.
No collection, replay, simulator, training run or test execution was launched.
