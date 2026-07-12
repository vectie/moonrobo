# Resilience qualification

MoonRobo qualifies recovery structure before MoonMoon calibrates its dynamics.
A `moonrobo.resilience-plan.v1` declares redundancy, degradation limits, safe
modes, recovery capabilities, hardware assumptions, and deterministic fault
scenarios. The qualifier records the state path for each scenario:

`normal -> degraded -> diagnosis -> recovery-attempt -> recovered/reduced-mission`

If a fault is unobservable or exceeds the declared recovery budget, the robot
uses a declared safe-return mode or fails closed. Qualification requires both a
successful bounded recovery/reduction and an exercised terminal safety path.

The resulting `simulation-ready` claim is design evidence only. It is not a
calibrated digital twin, hardware qualification, or physical deployment
authority. MoonMoon must independently bind testbed/source calibration and
uncertainty before raising the digital evidence claim.

Run:

```sh
moon run cmd/resilience -- examples/resilience/lunar-work-robot.json /tmp/resilience-qualification.json
```
