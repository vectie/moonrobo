# Explore recorded channel lag correlation

Use this offline tool when a recorded command and response appear similar but displaced in time. It shows every requested lag so you can inspect competing peaks and overlap counts, rather than silently changing either recording's clock.

```
moon run cmd/telemetry_correlation --target native -- examples/telemetry/correlation-shifted.csv --left command --right response --max-lag 3
```

Append `--csv` for an openable lag table or `--svg` for a self-contained plot. The default JSON includes the SHA-256 of the exact input bytes, original observations with source sample indexes, settings and all lag results. Int64 timestamps, intervals and lag milliseconds are encoded as decimal strings to preserve exact values. Redirect stdout to a new file to keep an output. The tool does not modify the input.

The sample has a descriptive perfect relationship at +2 samples (+20 ms), using six overlapping pairs. Positive lag means pair left[i] with later right[i+lag]. Negative lag means pair later left with earlier right. This convention is also recorded in the output. CSV start indexes refer to the selected sample array; each entry in the JSON sample array retains its zero-based original source index and exact timestamp.

## Method and scope

- Choose two numeric channels from the same recording and optionally an inclusive absolute recorded-time window with `--window START_MS END_MS`. Choosing the same channel gives autocorrelation.
- Every input row is validated before selection. Selected observations must be 3–2048 samples with exactly uniform positive Int64 millisecond spacing. No interpolation, padding, circular wrapping or gap bridging occurs. If intentional, use the existing separate resampling workflow and inspect its output first.
- Specify a nonnegative integer maximum lag. Every lag from negative maximum through positive maximum is reported and must leave at least three overlapping pairs.
- At each lag, compute Pearson r using that overlap's separate arithmetic means and sums of centered products. Independent finite-value scaling limits overflow. r is unitless and bounded to [-1,1]. Very small unresolved numeric variance, or a constant overlapping signal, produces null/blank and an explicit undefined status. It never becomes zero correlation.
- Each lag has a different overlap and potentially different statistical stability. Trends, short windows, repeated oscillations and searching many lags can produce misleading peaks. This tool provides no confidence interval, significance estimate or automatic best-lag choice.
- The native CLI accepts up to 4 MiB after reading; the pure API accepts up to 4 Mi UTF-16 code units. Source records are limited to 100,000. These are processing bounds, not a streaming memory guarantee.

A similarity peak is not calibrated device latency, causal evidence, physical readiness, a clock synchronization correction, control authority or permission to dispatch. This is recorded-data exploration under MoonRobo's telemetry inspection role. No provider, network, robot, firmware or hardware bridge is used.

## Reuse the data

Keep JSON alongside CSV or SVG to preserve input identity and source drillback. The lag table is an analysis table rather than timestamped telemetry; it is not presented as a new observed recording. Use the existing time-domain plot and selected original observations to investigate any promising lag.

## Checks

`moon test src/telemetry_csv` includes signed-lag symmetry, exact near-limit timestamps, undefined variance, large and small finite scales, input validation and safe output. `scripts/verify_correlation_workflow.mbtx` exercises the built native executable and writes reusable samples and its assertions. Broader cockpit, installed distribution and physical execution remain separate gates.
