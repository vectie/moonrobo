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

The current slice renders a read-only sample cockpit. The next step is to load
`public/sample-cockpit.json` from the Moonrobo service endpoint, then replace
that fixture with live `cockpit` and `cockpit-sdk-file` projections exposed by
the Lepus desktop host.
