# Closed-loop actor-adapter experiment

Runs the frozen LunaKine CPU reference with actual MuJoCo sensor feedback and the
same constrained adapter, observation encoder, history, previous applied action
and reference progression used on Ascend. No E1 SDK or network participant is
created. Arguments:

```
BUNDLE REFERENCE CONFIG SAVED_POSE MUJOCO_LIBRARY SUSPENDED_SCENE NEW_REPORT
```

The supplied scene must represent the intended supported experiment. The dated
deployment test welds the root to world as a crane approximation and preserves
the scene's force limits/inertia. It does not identify physical firmware torque
limits or qualify whole-body calibration. Both raw actions and applied candidate
commands are checked for sensitivity to a perturbed elbow observation. The
report distinguishes fixed leg **targets** from measured simulated displacement.
