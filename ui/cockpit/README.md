# Moonrobo Cockpit Shell

This is the first product-facing cockpit surface for the Rabbita/Lepus path.
It is intentionally data-driven: the UI renders the MoonBit cockpit projection
JSON and does not reimplement RobotBook parsing, safety checks, or bridge
semantics in browser code.

## Contract

Generate the payload from the native runtime:

```bash
moon run cmd/main --target native -- cockpit > ui/cockpit/sample-cockpit.json
```

For a read-only SDK sidecar snapshot:

```bash
python3 bridges/sdk_e1/sdk_e1_readonly_bridge.py --once > /tmp/moonrobo-sdk-e1.json
moon run cmd/main --target native -- cockpit-sdk-file examples/noetix-e1 /tmp/moonrobo-sdk-e1.json > ui/cockpit/sample-cockpit.json
```

The same payload is the input for the future Rabbita package and the Lepus
desktop shell. This static shell exists to lock down first-screen product shape
before the framework package is wired.

## First Screen

The shell keeps these signals above the fold:

- RobotBook identity and readiness
- bridge health, mode, and telemetry freshness
- digital twin body and joint summary
- latest telemetry frame
- safety-gated command review
- latest receipt evidence

Execution is locked in this slice. High-control actions should remain disabled
until the MoonBit safety verdict explicitly permits execution and Lepus has a
supervised live bridge.
