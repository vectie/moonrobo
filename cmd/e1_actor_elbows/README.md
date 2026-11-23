# Constrained E1 actor owner

This executable runs the frozen 23-joint SMC model on LunaKine's Ascend backend.
Fresh decoded E1 status, IMU, ten observation frames and the typed reference
enter every inference. Only SDK elbow-pitch motors 3 and 14 receive model-derived
position targets; the other 22 complete command records retain the sampled hold.
The inverse of the **applied command**, including held joints, is the next
observation's previous action. Model failure stops the owner.

The experimental deployment profile grants 25% model authority, ramps it over
two seconds, filters over 500 ms and uses the speed/envelope of the completed
elbow commissioning path. A ten-second model-driven approach holds the first
reference goal before advancing the 13.52-second typing reference. Baseline and
return are explicitly deterministic handover phases. This is a modified,
elbow-constrained policy, not qualification of the unmodified whole-body model.

Required environment variables are `MOONROBO_E1_ACTOR_BUNDLE`,
`MOONROBO_E1_ACTOR_MODEL`, `MOONROBO_E1_ACTOR_CONFIG`,
`MOONROBO_E1_ACTOR_REFERENCE` and `MOONROBO_E1_CANN_LIBRARY`.
Artifact hashes are verified before opening the NPU. Invoke
`e1_actor_elbows.exe actor-elbows NEW_REPORT [--shadow]` only through the staged
supervisor, which supplies decoded status on stdin and archives stdout proposals.
`--shadow` disables physical following-error checking because commands are not
executed. It preserves the validated stationary/glitch history and reports
nominal SDK leg-range discrepancies without treating raw feedback as unit-zero
calibration. Elbow bounds, motor errors, continuity and timing remain enforced.
Powered admission retains strict SDK leg-range checks. Shadow does not create
a command publisher, and its marked proposals are rejected by the powered
transport. The supervisor selects the January transport or a file sink.

See [deployment evidence](../../docs/E1_ACTOR_CONTROL_20261121.md) and
[transport instructions](../../deploy/e1/README.md). No boot service, website
button or LLM request activates this controller.
