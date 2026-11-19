# Learned Balance: Platform Registration And Thirty-Second Evaluation

Updated: 2026-10-23. The [learned ankle feedback](G1_LEARNED_BALANCE_FEEDBACK.md)
has a concrete limit: full causal memory completes the observed ten-second
canonical suite, but all six extended wave trials fall, averaging 11.88 s.
Stand and sway complete thirty seconds. Four experiment records preserve both
durations and both memory arms through the existing MoonData comparison API.

## Frozen Duration Comparison

[`g1-learned-balance-long.json`](../examples/learning/g1-learned-balance-long.json)
fixes the three parent seeds, unchanged/H10/full modes, stand/sway/wave cases,
thirty-second cap and reset seeds 9900/10000 before running. Reset 9900 repeats
an original condition; 10000 is a new condition. There is no new fitting,
checkpoint selection, exploration noise or parameter tuning.

The 54 new physical episodes contain 59,295 actual transitions. Across 27
repeated-condition episodes, 12,269 original prefix steps match exactly in
states, observations, goals, applied actions, rewards and termination flags.
Only time-limit truncation can change when extending a surviving episode.
The ten-second result therefore does not arise from a different controller or
initialization in these extended trials.

| Frozen mode | Falls / 18 cells | Mean survival (s) | Mean joint RMSE (rad) | Wave survival (s) |
| --- | ---: | ---: | ---: | ---: |
| Unchanged parent | 8 | 18.39556 | 0.047603 | 2.59333 |
| Learned H10 | 6 | 23.52778 | 0.038848 | 10.58333 |
| Learned full memory | 6 | 23.96000 | 0.038647 | 11.88000 |

Both learned arms complete all six stand and six sway trials, but fail all
six wave trials. Full-memory wave failures occur after ten seconds. Each
parent with either learned arm has two falls in six trials. The earlier
independent-joint-sine failures also remain unresolved. Full memory improves
short-horizon behavior and delays falls; it does not establish sustained
whole-body control. No learned arm passes the thirty-second suite.

The numerical provider takes 81.96 s for the longer rollouts and serialization,
excluding loading/verifying prior data and any original training. This is a
local CPU measurement, not a matched training-efficiency result.

## Exact Training Export And Existing Platform Contract

[`learned_balance_export.py`](../providers/motion_learning/learned_balance_export.py)
materializes all 54 fitted training episodes with separate float32 teacher
targets. Recomputing the two closed-form fits from these points reproduces all
six saved heads tensor-for-tensor, including normalization. The complete archive
has six source chunks and 19,390 points. A separate first-chunk dataset is a
representative reader input, not a claim to contain all training episodes.

The new producer format is `moonrobo.g1-learned-balance-fit.v1`. The importer
requires the training archive, training-source manifest, full evaluation archive
and original study reports, alongside the usual selected/latest checkpoint and
per-seed baseline/candidate physics report. No dynamics report or critic is
fabricated. Checkpoints remain the distinct composite format
`moonrobo.g1-learned-balance-actor.v1`, with embedded parent and observer.

The source archives retain the ten-second independent training-family audit
as well as canonical trials. Existing short trials did not capture viewer
replays, so their trace geometry/contact counts are reconstructed from recorded
`next_state` using the pinned model, without advancing physics or rerunning a
policy. The report explicitly labels this reconstruction. New thirty-second
trials capture their viewer traces during rollout. A numerical test checks
reconstruction against captured physics, including contacts and root rotation.

Four registered experiments under `target/learning/experiment-book/moondata`
are inspectable with the existing comparison table and per-seed trace route:

| Experiment ID | Duration | Producer numeric passes / 3 parent contexts |
| --- | ---: | ---: |
| `balance-h10-ten-second` | 10 s | 2 |
| `balance-full-ten-second` | 10 s | 3 |
| `balance-h10-thirty-second` | 30 s | 0 |
| `balance-full-thirty-second` | 30 s | 0 |

`producer_qualified` means zero falls and mean joint RMSE ≤0.15 rad within the
declared development duration. It is not release qualification. `seed` names
the frozen parent training seed; each arm shares one deterministic fitted head.
Twelve registered evaluation contexts represent six distinct composite weights
and two fitted heads, not twelve independent training runs. Shared archive and
checkpoint bytes deduplicate in the existing BlobStore. Physical execution is
false for every record, including numeric passes.

## Evidence And Reproduction

The [platform/duration report](../output/research/g1-learned-balance-platform-study.json)
binds the fit, export, long evaluation, native validation and registered payloads.
The full long-study directory is `target/learning/g1-learned-balance-long`;
`target/learning/g1-learned-balance-registration` contains four producer folders
and the shared train archive. Original fitted weights remain unchanged.

All six training chunks and nine long-evaluation chunks pass the native dataset
reader, which validates all splits before emitting sampled endpoints. The
original nine short-evaluation chunks were validated in the preceding study.
The complete MoonData root validates with zero findings after registration.
Forty-eight provider tests, nine learning-registry tests and 118 host API tests
pass. The registry tests include shared labeled-data preservation, reopening
after deleting a source fixture, and rejection of a missing training record.
The generic API and cockpit need no format-specific code changes.

The [API readback record](../output/research/g1-balance-platform-views.json)
opens all four actual registered experiments through the existing native
`api-route` entry point. All twelve stored physics envelopes match their
exported reports, declare the correct ten/thirty-second duration and keep
physical execution false. This checks the data consumed by the viewer; it
does not claim a new browser interaction test.

```sh
moon run --target native scripts/verify_g1_learned_balance_long.mbtx REPO FIT_STUDY FRESH_LONG_OUTPUT
moon run --target native scripts/export_g1_learned_balance.mbtx REPO FIT_STUDY LONG_STUDY FRESH_EXPORT_OUTPUT
moon run --target native scripts/register_g1_learned_balance.mbtx REPO FIT_STUDY LONG_STUDY EXPORTED MOONDATA NOW_MS OUTPUT_JSON
moon run --target native scripts/verify_g1_balance_views.mbtx REPO EXPORTED ROBOBOOK_ROOT OUTPUT_JSON
```

Older completed-study JSON inputs/reports were losslessly archived as `.json.gz`
to make room for new evidence. Their sealed MoonData bytes remain unchanged;
restore the original filename before rerunning older scripts that require JSON.

The subsequent [long balance diagnosis](G1_LONG_BALANCE_DIAGNOSIS.md) performs
those oracle/channel comparisons: the original full teacher still fails. A
training-only parameter search then supplies a stronger privileged teacher,
completing all 36 new thirty-second checks. That result has not yet transferred
to a learned policy. Broader motion coverage, matched world-model/PPO efficiency,
complete workbench, E1 and hardware phases remain open.
