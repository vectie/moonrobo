# E1 trained 23-joint actor deployment — 20 November 2026

The frozen actor is installed on Atlas `.191` and has executed against live E1
telemetry through LunaKine/Ascend. **Motor activation is not qualified and was
not enabled.** Three bounded 15-second shadow runs completed, each with 750
updates at 50 Hz and no missed periods. The processes have exited; no actor
control service or automatic startup was installed.

The [evidence manifest](evidence/e1-trained23-shadow-20261120.json) records the
model identities, executable/plugin hashes, measured timings, target checks and
independent numerical comparison. Raw inputs, traces and reports are retained
outside Git under `output/e1-trained23-live-shadow-20261120-DFKZGg`.

## Installed model and motor profile

The selected model is the existing E1 iteration-14,000 parent with the
100-update arm-reference fine-tune, exported from
`output/e1-arm-finetune-20261115/train/evaluation-100/actor`. It is not a new
training run or the separate, in-progress 24-axis re-embodiment work. The source
experiment's `RESULT.md` reports mixed simulation results between parent and
fine-tune; neither report qualifies physical whole-body control.

The deployed contract is `noetix-e1-23-lab-v1`: history `[1,10,99]`, raw preview
`[1,730]`, 29 internal output channels with only the first 23 active. Saved
normalization, feature scales and `default_q + scales * action` are preserved.
The portable actor, parameters, robot companion and previously compiled OM were
hash-matched to the selected artifacts before use.

The installation is:

```text
/home/jiaanguo/lunakine-deployment-20261117/trained23-20261120-DFKZGg
  actor/                         frozen portable bundle
  actor.om                       existing Ascend 310P3 FP32 compilation
  libe1_readonly_status.so        reviewed receive-only DDS adapter
  shadow-config.json             explicitly unqualified diagnostic calibration
  moonrobo/                      deployment-only MoonBit source and executable
  lunakine/                      separate numerical actor runtime
  shadow-report*.json             measured run summaries
  preflight-before-shadow.json
  preflight-after-shadow.json
```

The Noetix `E1+SDK开发指南.pdf` motor table on page 10 lists ID 22 as waist yaw
and ID 23 as reserved (`备用`). The runner reads and validates all 24 status
records, maps the 23 physical actor joints to SDK slots 0–22, and leaves slot 23
inactive. No inference about an unused motor physically inside the robot is
needed. This deployment does not expose a waist-roll action.

## Live shadow results

The read-only status plugin constructs a DDS participant and status reader;
its publish entry point rejects commands. It does not construct the vendor
controller or a motor/mode writer. Its source matched the reviewed local status
reader and fixed-width 24-record decoder. A discovery preflight passed before
the run and again after the final run, rejecting existing command writers and
checking healthy, complete telemetry. The existing telemetry receiver was left
running. The NPU was healthy and had no remaining inference process afterward.

| Measurement | Run 1 | Run 2 | Run 3 |
| --- | ---: | ---: | ---: |
| Duration | 15 s | 15 s | 15 s |
| Actor updates | 750 | 750 | 750 |
| Missed 20 ms periods | 0 | 0 | 0 |
| Maximum scheduling lateness | 1 ms | 1 ms | 1 ms |
| Maximum inference time | 3 ms | 3 ms | 3 ms |
| Maximum callback-to-output age | 5 ms | 6 ms | 5 ms |

These are observed short-run maxima using millisecond timestamps, not a
worst-case latency guarantee. Callback age excludes sensor/device queuing.

All 2,250 recorded frames contain IDs 0–23, the exact 23-joint-to-slot mapping,
zero inactive actor channels, a zero reserved-slot preview target, and
`published:false`. Preview gains are zero because these commands are recorded
only; they are not a usable powered control configuration.

The diagnostic reference freezes the current measured joint pose. Its root
orientation is anchored to the same calibrated body rotation as the observer;
the preview removes heading using the training encoder's convention. Run 1
used the earlier upright reference, and runs 2–3 use the corrected attitude
alignment. This stationary diagnostic was not an evaluated training skill.
Open-loop shadow observations cannot establish closed-loop stability.

## What prevents motor activation

In the final run, the left ankle-roll nominal PD target was
`0.5334923537–0.9844462740 rad` (about **30.6–56.4°**) while its baseline measured
angle was `0.0423415226 rad` (about 2.4°). This target exceeded the selected
simulation scene's joint travel `[-0.26,0.26] rad` in all 750 frames. It is a
persistent policy output, separate from the earlier isolated ankle telemetry
spikes. Correcting the reference's attitude/heading did not remove it.

The simulation's position actuators explicitly use `ctrllimited="false"` with
force limits. A PD target outside joint travel is therefore not, by itself,
evidence of a broken export or an invalid training action. The scene's travel
range is also **not a verified physical SDK command limit**. The delivery
manual's asymmetric ankle ranges do not resolve that question. Silently
clipping the policy to the scene range would change its control behavior and
would require evaluation of that changed behavior.

The final trace records the exact 99 raw observation values and the report
records all 730 raw goals. Eight inputs spanning startup, history rollover and
the final frame were replayed through independent ONNX Runtime CPU FP32 using
the same ONNX artifact. Across 232 outputs the maximum difference from Ascend
was **0.00000286102294921875**, below the existing `0.0001` comparison tolerance.
This supports numerical execution parity for those captured inputs; it does
not establish joint calibration or policy quality.

The supplied shadow configuration explicitly uses candidate joint directions
`+1`, zeros `0`, and identity IMU mounting/world transforms. Plausible telemetry
and a previously successful deterministic elbow trial do not verify these
whole-body conventions or the learned policy's hardware gains and torque
limits. Before powered actor control, resolve those mappings and the effective
hardware actuator behavior, then evaluate an actual prepared training reference
and any required action projection in simulation and live shadow. A powered
commissioning trial must then use the correct January protocol and a current
physical support/operator check. The newer SDK 3.1 writer is not substituted
for that previously tested transport.

## Reproducing the software checks

The deployment runner imports no training package. Build/check/test it with the
selected MoonBit toolchain and native compiler:

```sh
moon check --target native --deny-warn --warn-list +73 cmd/e1_live_actor_shadow
moon test --target native --deny-warn --warn-list +73 cmd/e1_live_actor_shadow src/sdk_e1_policy
moon test scripts/prepare_e1_live_actor_shadow.mbtx
```

The native package tests passed seven cases; the configuration parser passed
its range-attribute regression. Scoped `moon info` and formatting were run. The
only intended public interface addition is `ImuFeatures::body_to_world()` so
reference anchoring reuses the observation decoder's calibrated rotation.

An attempted strict build of the separate full `e1_train` executable failed
on existing warning-denied findings in training dependencies (111 diagnostics,
including deprecated conversions and implicit derived methods). Those policies
were not relaxed. This does not affect the separately built, strictly checked
deployment runner; a fresh full training/export rebuild was not claimed.

Create a minimal source view with
`scripts/stage_lunakine_actor_host.mbtx REPO NEW_OUTPUT status-shadow`, alongside
the LunaKine source. Generate its explicitly shadow-only configuration with
`scripts/prepare_e1_live_actor_shadow.mbtx REPO BUNDLE MODEL_SCENE_XML NEW_CONFIG`.
The runner's command line is:

```text
e1_live_actor_shadow BUNDLE CANN_LIBRARY MODEL_OM READONLY_STATUS_PLUGIN CONFIG_JSON NEW_REPORT_JSON
```

On the current host, select CANN's actual
`/home/jiaanguo/Ascend/cann-9.1.0/lib64/libascendcl.so`, its `lib64`/driver library
paths, and the reviewed DDS configuration bound to `eno1`/`192.168.55.101` with
peer `192.168.55.102`. Select `libe1_readonly_status.so`, not a powered SDK
adapter. Redirect stdout to a new NDJSON trace. Existing report paths are
rejected rather than overwritten.

The independent replay uses exact captured raw actor inputs:

```sh
moon run scripts/compare_e1_live_shadow_onnx.mbtx prepare TRACE REPORT NEW_INPUTS NEW_EXPECTED
polygraphy run ACTOR_ONNX --onnxrt --load-inputs INPUTS --save-outputs NEW_OUTPUTS
moon run scripts/compare_e1_live_shadow_onnx.mbtx check EXPECTED OUTPUTS NEW_COMPARISON
```

The helper reconstructs only the recorded history sequence, including the
ten-frame repeated startup observation. Normalization stays inside the ONNX
model; no sensor convention is guessed during replay. It reports an
Ascend-versus-CPU comparison, not a new upstream LibTorch qualification.
