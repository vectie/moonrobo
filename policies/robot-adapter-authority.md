# Robot adapter authority

- `robot.integrate-digital-model` requires `WorkspaceMutation`, accepts only a
  `digital-only` robot design and may claim no more than `digital-artifact`.
- `robot.readiness.inspect` requires `Observe`; blocked readiness is evidence,
  not an adapter failure or a readiness claim.
- `robot.command.submit-governed` requires `WorkspaceMutation`. It may create a
  durable task message but cannot execute a bridge command.
- The adapter exposes no `physical-effect` authority.
- All physical effects require MoonRobo readiness, exact robot/bridge identity,
  current runtime evidence, dry-run and approval where required, and a
  separately granted physical authority envelope.
- Unknown outcomes reconcile from the attempt receipt, design receipt or
  gateway-command evidence before MoonFlow may create another attempt.
