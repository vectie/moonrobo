# Adapter conformance evaluation

Release validation must prove:

1. `pack.json` compiles in MoonFlow’s capability catalog with the checked-in
   `moonflow.adapter-declaration.v1`.
2. Runtime health evidence covers only operations whose current readiness
   probe passed.
3. Repeating an exact request returns the original terminal result.
4. A started attempt cannot be invoked again until reconciliation.
5. Reconciliation recovers an integration or command submission from
   product-owned evidence and classifies absent evidence as `not-applied`.
6. Partial, conflicting or identity-mismatched artifacts remain
   `unknown`/blocked rather than being retried.
7. Every operation receipt records
   `physical_execution_performed: false`.

Physical hardware qualification is a separate release gate and cannot be
inferred from adapter conformance.
