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

The current slice renders a sample immediately, then loads
`/api/cockpit/snapshot` through Rabbita's HTTP command path. The native
`src/host_api` package owns that route contract; the next step is for the Lepus
desktop host to serve it.
