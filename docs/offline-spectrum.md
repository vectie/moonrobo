# Recorded signal spectrum

`telemetry_spectrum` opens numeric telemetry CSV and exports a one-sided amplitude
spectrum for one named channel. This offline explorer does not infer a physical
condition, command outcome, safety or robot state.

```text
telemetry_spectrum examples/telemetry/spectrum-two-tone.csv --channel voltage --unit V
telemetry_spectrum examples/telemetry/spectrum-two-tone.csv --channel voltage --unit V --demean --svg
telemetry_spectrum recording.csv --channel acceleration --unit m/s^2 --window 1000 1990
```

Build native `cmd/telemetry_spectrum`. JSON is the default. Its envelope includes
the exact source-byte SHA-256; the spectrum retains every selected original
value, exact timestamp and zero-based source row index. Keep raw CSV and JSON
beside an SVG. A hash is byte identity, not freshness, hardware provenance,
command identity or authentication.

## Sampling and window

The whole CSV is validated first. Inclusive recorded-time bounds select 2..2048
observations. Every adjacent selected timestamp difference must be the same
positive exact Int64 millisecond count. Irregular spacing and gaps refuse; choose
an uninterrupted window. No samples are resampled, padded, filled, sorted,
dropped from inside the window or inferred. Exact subtraction precedes frequency
calculations, so millisecond steps near the Int64 maximum survive a large origin.

The only analysis window is rectangular: every observation has weight one.
`--demean` subtracts the selected arithmetic mean before transformation; original
observations stay intact. Default processing retains the mean. There is no
detrending, Hann window, overlap, smoothing, FFT or spectral fitting.

## Amplitude meaning

For N samples x[n], bins k=0 through floor(N/2) are evaluated directly:

`X[k] = sum(x[n] * exp(-i * 2*pi*k*n/N))`

- Sample rate Fs = 1000 / exact interval_ms, in Hz.
- Bin spacing = Fs / N. Frequency at bin k = k * Fs / N.
- Nyquist frequency = Fs / 2. Odd N has no bin exactly at Nyquist.
- Base amplitude = abs(X[k]) / N.
- Double interior bins; leave DC and even-N Nyquist undoubled.
- Amplitudes carry the supplied input unit label. These are peak amplitudes,
  not RMS, power, energy or power spectral density.

A bin-centered sinusoid's amplitude is recovered under these conventions. DC is
the magnitude of the mean unless demeaning is selected. Rectangular-window
leakage spreads off-bin tones. Bin spacing does not guarantee that two physical
frequencies can be resolved. Sampling can alias frequencies; this tool does not
detect/correct aliasing or assess acquisition quality. No calibration or unit
conversion is inferred from the label.

JSON and SVG show N, interval, sample rate, bin spacing, Nyquist, demeaning,
window, units and normalization. SVG stems show discrete bins with numerical
tooltips rather than implying observations between frequencies.

The fixture is `1 + 2*cos(2*pi*n/8) + 3*sin(4*pi*n/8)` at 125 ms spacing. It has
DC amplitude 1 V, 1 Hz amplitude 2 V and 2 Hz amplitude 3 V. Reopen the same input
with `telemetry_csv` and `telemetry_plot` to compare the time-domain view.

## Limits and verification

Direct DFT is O(N²), capped at 2048 selected observations and 100000 source rows.
The native input cap is 4 MiB after reading; the pure API also bounds text at
4 Mi UTF-16 units. Unrepresentable amplitude refuses instead of serializing
infinity. Errors go to stderr with nonzero exit and no successful output. Shell
redirection may create an empty file before a refused command begins.

Run `scripts/verify_spectrum_workflow.mbtx` with absolute source and native target
paths plus a NEW evidence directory. It exercises actual JSON/SVG, known
amplitudes, demeaning, time-domain reopen and CLI refusals. Native and portable
tests cover DC, Nyquist, sine, two-tone, odd/even N, exact large timestamp origins,
gap refusal, units and bounds. This is source-scope offline inspection; MoonData,
cockpit, bridge, physical proof and release gates remain separate.
