# Digital model to governed robot work

```text
moonsuite.robot-design.v1
→ robot.integrate-digital-model
→ named human review of the digital artifact
→ robot.readiness.inspect
→ optional MoonClaw reasoning
→ robot.command.submit-governed
→ MoonRobo task, dry-run, approval, runtime and bridge gates
→ telemetry and outcome evidence
→ MoonBook Bookkeeper
```

The first operation accepts the exact cross-product operation ID already used
by the robotics composition graph. MoonFlow binds it canonically as
`moonrobo/robot.integrate-digital-model@0.2.0`.

Submitting governed work is not physical execution. It records a task goal and
returns MoonRobo’s next safe boundary. The task may subsequently be rejected,
reviewed, simulated, approved or executed by the product-owned physical lane.
