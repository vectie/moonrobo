# Moonrobo Rabbita Cockpit

This is the first MoonBit/Rabbita operator surface for Moonrobo. It renders the
`vectie/moonrobo/src/cockpit` projection contract directly, so robot parsing,
safety decisions, and bridge semantics stay in the MoonBit runtime packages.

## Run

```bash
moon build --target js --debug
node prepare-rabbita-build.mjs debug
npm run dev
```

## Build

```bash
moon build --target js --release
node prepare-rabbita-build.mjs release
npm run build
```

The current slice renders a sample immediately, loads `/api/cockpit/snapshot`,
and lets the operator edit a high-level walk proposal before submitting it to
`/api/intents/evaluate`. That endpoint only evaluates the safety gate and writes
a RobotBook receipt; it does not execute hardware commands.

The native `src/host_api` package owns those route contracts, and
`src/desktop_host` serves them beside the built Rabbita assets for the Lepus
desktop shell.
