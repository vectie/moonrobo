#!/usr/bin/env node
// Same-row recorded tracking error. No alignment, calibration, or device operations.
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { label, time, parseRecording } from './telemetry-recording.mjs';

const MAX_BYTES = 4 * 1024 * 1024;
const ERROR_CHANNEL = 'tracking_error';
const digest = text => createHash('sha256').update(text).digest('hex');
const zero = value => value === 0 ? 0 : value;
function sum(values) {
  let total = 0, correction = 0;
  for (const value of values) {
    const next = total + value;
    correction += Math.abs(total) >= Math.abs(value) ? (total - next) + value : (value - next) + total;
    total = next;
  }
  return total + correction;
}
function statistics(errors) {
  if (!errors.length) return { bias: null, mae: null, rmse: null, max_abs_error: null };
  const scale = errors.reduce((maximum, value) => Math.max(maximum, Math.abs(value)), 0);
  if (scale === 0) return { bias: 0, mae: 0, rmse: 0, max_abs_error: 0 };
  // Scale before summing or squaring; all normalized terms have magnitude <= 1.
  // Clamp rounding at the known mathematical bounds before restoring the scale.
  const values = errors.map(value => value / scale);
  const bias = Math.max(-1, Math.min(1, sum(values) / values.length)) * scale;
  const mae = Math.min(1, sum(values.map(Math.abs)) / values.length) * scale;
  const rmse = Math.sqrt(Math.min(1, sum(values.map(value => value * value)) / values.length)) * scale;
  if (![bias, mae, rmse].every(Number.isFinite)) throw new Error('statistics overflow: no report produced');
  return { bias: zero(bias), mae, rmse, max_abs_error: scale };
}

/** Two selected columns from one complete recording; the caller declares compatible units. */
export function trackingError(text, { requested, measured, commonUnit, window = null } = {}) {
  label(requested, 'requested'); label(measured, 'measured'); label(commonUnit, 'commonUnit');
  if (requested === measured) throw new Error('requested and measured must be distinct channels');
  if (typeof text !== 'string' || Buffer.byteLength(text, 'utf8') > MAX_BYTES) throw new Error('recording: expected UTF-8 text of at most 4 MiB');
  let bounds = null;
  if (window !== null) {
    if (!Array.isArray(window) || window.length !== 2 || window.some(value => typeof value !== 'string')) throw new Error('window: expected two decimal-string millisecond bounds');
    bounds = window.map(value => time(value, 'window'));
    if (bounds[0] > bounds[1]) throw new Error('window: start exceeds end');
  }
  // Complete-source parsing precedes any selection; invalid unrelated cells are errors.
  const recording = parseRecording(text);
  const requestedColumn = recording.channels.indexOf(requested), measuredColumn = recording.channels.indexOf(measured);
  if (requestedColumn < 0 || measuredColumn < 0) throw new Error('selected channel is absent from recording');
  const samples = recording.rows.filter(row => !bounds || (BigInt(row.timestamp_ms) >= bounds[0] && BigInt(row.timestamp_ms) <= bounds[1])).map(row => {
    const requestedValue = row.values[requestedColumn], measuredValue = row.values[measuredColumn];
    const error = measuredValue - requestedValue;
    if (!Number.isFinite(error)) throw new Error(`line ${row.source_line}: measured minus requested overflows finite binary64`);
    return { ...row, requested_value: requestedValue, measured_value: measuredValue, error: zero(error) };
  });
  const report = {
    format: 'moonrobo.telemetry-tracking-error.v1',
    method: 'same-row-measured-minus-requested-scaled-sample-statistics.v1',
    interpretation: 'recorded numeric differences only; not physical tracking qualification, calibration, readiness, safety or successful execution',
    source_sha256: digest(text),
    timebase: 'milliseconds-as-recorded',
    requested_channel: requested, measured_channel: measured, common_unit: commonUnit,
    unit_declaration: 'caller declares both channels already share compatible meaning and this unit; no conversion or verification',
    sign_convention: 'error = measured - requested; positive means measured is greater',
    weighting: 'equal weight per recorded row, not elapsed time; no alignment, interpolation, hold or gap filling',
    arithmetic: 'finite binary64 differences; compensated scaled means and RMS; not exact decimal arithmetic',
    window: bounds?.map(value => value.toString()) ?? null,
    source_span: [recording.rows[0].timestamp_ms, recording.rows.at(-1).timestamp_ms],
    total_source_samples: recording.rows.length, sample_count: samples.length,
    selected_span: samples.length ? [samples[0].timestamp_ms, samples.at(-1).timestamp_ms] : null,
    ...statistics(samples.map(row => row.error)),
    channels: recording.channels, samples,
    error_channel: ERROR_CHANNEL,
    export_warning: 'CSV retains timestamps and error only; keep this JSON and the source for channel, unit and source identity',
  };
  report.error_csv_sha256 = samples.length ? digest(trackingErrorCsv(report)) : null;
  return report;
}

// Accepts an unmodified successful trackingError report, not arbitrary imported objects.
export function trackingErrorCsv(report) {
  if (!report.samples.length) throw new Error('empty window: no reusable error CSV samples; inspect JSON instead');
  // Fixed header excludes source-controlled labels and units from the numeric CSV.
  return `timestamp_ms,${ERROR_CHANNEL}\n` + report.samples.map(row => `${row.timestamp_ms},${row.error}`).join('\n') + '\n';
}

const usage = 'node scripts/telemetry-tracking-error.mjs INPUT.csv --requested CHANNEL --measured CHANNEL --common-unit UNIT [--window START_MS END_MS] [--format json|csv]';
export function main(args) {
  if (args.length === 1 && args[0] === '--help') return usage + '\n';
  const [input, ...rest] = args;
  if (!input || input.startsWith('--')) throw new Error(usage);
  const options = {}, seen = new Set();
  let format = 'json';
  const keys = new Map([['--requested', 'requested'], ['--measured', 'measured'], ['--common-unit', 'commonUnit']]);
  for (let i = 0; i < rest.length; i++) {
    const key = rest[i];
    if ((!keys.has(key) && !['--window', '--format'].includes(key)) || seen.has(key)) throw new Error(`unknown or repeated option: ${key}`);
    seen.add(key);
    const value = rest[++i];
    if (value === undefined || value.startsWith('--')) throw new Error(`missing value for ${key}`);
    if (key === '--window') {
      const end = rest[++i];
      if (end === undefined || end.startsWith('--')) throw new Error('window: missing end timestamp');
      options.window = [value, end];
    } else if (key === '--format') format = value;
    else options[keys.get(key)] = value;
  }
  if (!['json', 'csv'].includes(format)) throw new Error('format: expected json or csv');
  const bytes = readFileSync(input);
  if (bytes.length > MAX_BYTES) throw new Error('recording: expected UTF-8 text of at most 4 MiB');
  const text = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes);
  const report = trackingError(text, options);
  report.input_file = input;
  return format === 'csv' ? trackingErrorCsv(report) : JSON.stringify(report, null, 2) + '\n';
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try { process.stdout.write(main(process.argv.slice(2))); }
  catch (error) { process.stderr.write(JSON.stringify({ error: error.message }) + '\n'); process.exitCode = 2; }
}
