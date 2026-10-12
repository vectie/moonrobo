#!/usr/bin/env node
// Explore recorded association only. Never infer a physical latency or alter clocks.
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { parseRecording, toCsv } from './telemetry-distribution.mjs';

const MAX_TIME = 9223372036854775807n;
const MAX_SAMPLES = 8192;
const MAX_LAG = 256;
function label(value, field) {
  if (typeof value !== 'string' || !value.trim() || /[\x00-\x1f\x7f]/.test(value)) throw new Error(`${field}: expected printable nonblank label`);
}
function timestamp(value) {
  if (typeof value !== 'string' || !/^\d+$/.test(value) || BigInt(value) > MAX_TIME) throw new Error('window: expected nonnegative Int64 decimal strings');
  return BigInt(value);
}
function sum(values) {
  let total = 0, correction = 0;
  for (const value of values) {
    const next = total + value;
    correction += Math.abs(total) >= Math.abs(value) ? (total - next) + value : (value - next) + total;
    total = next;
  }
  return total + correction;
}
function pearson(xs, ys) {
  const flatX = xs.every(x => x === xs[0]), flatY = ys.every(y => y === ys[0]);
  if (flatX || flatY) return { status: flatX && flatY ? 'both-constant' : flatX ? 'reference-constant' : 'response-constant', correlation: null };
  // Scale before centering to avoid overflow in large finite inputs or sums.
  const center = values => {
    const scale = values.reduce((m, x) => Math.max(m, Math.abs(x)), 0);
    const scaled = values.map(x => x / scale);
    const mean = sum(scaled) / values.length;
    return scaled.map(x => x - mean);
  };
  const x = center(xs), y = center(ys);
  const xx = sum(x.map(v => v * v)), yy = sum(y.map(v => v * v));
  const xy = sum(x.map((v, i) => v * y[i]));
  const raw = xy / Math.sqrt(xx) / Math.sqrt(yy);
  if (!Number.isFinite(raw)) return { status: 'numerically-unresolved', correlation: null };
  return { status: 'calculated', correlation: Math.max(-1, Math.min(1, raw)) };
}
function bounds(count, lag) { return [Math.max(0, -lag), Math.min(count, count - lag)]; }

/** Pearson association of reference[i] with response[i + lag], over real overlap only. */
export function scanLag(text, { reference, response, referenceUnit, responseUnit, maxLagSamples, minPairs, window = null } = {}) {
  for (const [field, value] of Object.entries({ reference, response, referenceUnit, responseUnit })) label(value, field);
  if (reference === response) throw new Error('reference and response must be distinct channels');
  if (!Number.isSafeInteger(maxLagSamples) || maxLagSamples < 0 || maxLagSamples > MAX_LAG) throw new Error(`maxLagSamples: expected integer from 0 to ${MAX_LAG}`);
  if (!Number.isSafeInteger(minPairs) || minPairs < 3) throw new Error('minPairs: expected integer of at least 3');
  let requestedWindow = null;
  if (window !== null) {
    if (!Array.isArray(window) || window.length !== 2) throw new Error('window: expected two inclusive timestamps');
    requestedWindow = window.map(timestamp);
    if (requestedWindow[0] > requestedWindow[1]) throw new Error('window: start exceeds end');
  }
  // Validate every channel and row, even outside the selected window.
  const recording = parseRecording(text);
  const xColumn = recording.channels.indexOf(reference), yColumn = recording.channels.indexOf(response);
  if (xColumn < 0 || yColumn < 0) throw new Error('selected channel is absent from recording');
  const samples = recording.rows.filter(row => !requestedWindow || (BigInt(row.timestamp_ms) >= requestedWindow[0] && BigInt(row.timestamp_ms) <= requestedWindow[1]));
  if (samples.length < 3 || samples.length > MAX_SAMPLES) throw new Error(`selected window must contain 3 to ${MAX_SAMPLES} samples`);
  if (minPairs > samples.length) throw new Error('minPairs exceeds selected sample count');
  if (maxLagSamples >= samples.length) throw new Error('maxLagSamples must be less than selected sample count');
  const interval = BigInt(samples[1].timestamp_ms) - BigInt(samples[0].timestamp_ms);
  for (let i = 2; i < samples.length; i++) {
    if (BigInt(samples[i].timestamp_ms) - BigInt(samples[i - 1].timestamp_ms) !== interval) throw new Error('selected timestamps must have one exact regular interval; select one uninterrupted window; no gap filling or interpolation is performed');
  }
  const lags = [];
  for (let lag = -maxLagSamples; lag <= maxLagSamples; lag++) {
    const [first, end] = bounds(samples.length, lag);
    const count = end - first;
    const score = count < minPairs ? { status: 'insufficient-pairs', correlation: null } : pearson(
      samples.slice(first, end).map(row => row.values[xColumn]),
      samples.slice(first + lag, end + lag).map(row => row.values[yColumn]),
    );
    lags.push({
      lag_samples: lag, recorded_offset_ms: (BigInt(lag) * interval).toString(), pair_count: count,
      reference_first_sample_index: samples[first].sample_index,
      reference_last_sample_index: samples[end - 1].sample_index,
      response_first_sample_index: samples[first + lag].sample_index,
      response_last_sample_index: samples[end - 1 + lag].sample_index,
      ...score,
    });
  }
  const positive = lags.filter(row => row.correlation !== null && row.correlation > 0);
  const highest = positive.reduce((max, row) => Math.max(max, row.correlation), 0);
  return {
    format: 'moonrobo.telemetry-lag.v1', method: 'overlap-centered-scaled-pearson.v1',
    interpretation: 'recorded association, not physical latency, causality, clock calibration, safety or successful execution',
    lag_convention: 'reference[i] pairs with response[i + lag]; positive lag compares later response observations',
    source_sha256: createHash('sha256').update(text).digest('hex'),
    reference_channel: reference, response_channel: response, reference_unit: referenceUnit, response_unit: responseUnit,
    window: requestedWindow?.map(v => v.toString()) ?? null,
    total_source_samples: recording.rows.length, sample_count: samples.length,
    first_timestamp_ms: samples[0].timestamp_ms, last_timestamp_ms: samples.at(-1).timestamp_ms,
    sample_interval_ms: interval.toString(), max_lag_samples: maxLagSamples, min_pairs: minPairs,
    pairing: 'overlap-only, equal weight per pair, separately centered for each lag; no padding, interpolation or extrapolation',
    highest_positive_association: positive.length ? { correlation: highest, lag_samples: positive.filter(row => highest - row.correlation <= 1e-12).map(row => row.lag_samples), candidate_tolerance: 1e-12, tie_rule: 'positive correlations within 1e-12 of the computed maximum; numerical grouping, not statistical uncertainty' } : null,
    channels: recording.channels, samples, lags,
  };
}

/** Explicit inspection/export choice, never an automatic clock correction. */
export function selectLag(report, lag) {
  if (!Number.isSafeInteger(lag)) throw new Error('lagSamples: expected signed integer');
  const summary = report.lags.find(row => row.lag_samples === lag);
  if (!summary) throw new Error('lagSamples: outside scanned range');
  if (summary.pair_count < report.min_pairs) throw new Error('lagSamples: fewer than the declared minimum pairs');
  const [first, end] = bounds(report.samples.length, lag);
  const xColumn = report.channels.indexOf(report.reference_channel), yColumn = report.channels.indexOf(report.response_channel);
  const pairs = [];
  for (let i = first; i < end; i++) {
    const reference = report.samples[i], response = report.samples[i + lag];
    pairs.push({
      pair_index: pairs.length,
      reference_sample_index: reference.sample_index, reference_source_line: reference.source_line,
      reference_timestamp_ms: reference.timestamp_ms, reference_value: reference.values[xColumn],
      response_sample_index: response.sample_index, response_source_line: response.source_line,
      response_timestamp_ms: response.timestamp_ms, response_value: response.values[yColumn],
    });
  }
  return { ...summary, export_timebase: 'reference observation timestamps; response values are lag-paired, not simultaneous', pairs };
}
export function lagCsv(report, lag) {
  const selection = selectLag(report, lag);
  return toCsv({ channels: [`reference:${report.reference_channel}`, `lagged-response:${report.response_channel}`], samples: selection.pairs.map(pair => ({ timestamp_ms: pair.reference_timestamp_ms, values: [pair.reference_value, pair.response_value] })) });
}
const escapeXml = text => String(text).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;' })[c]);
export function lagSvg(report) {
  const width = 900, left = 70, right = 865, top = 85, bottom = 325;
  const limit = report.max_lag_samples || 1;
  const x = lag => left + (lag + limit) / (2 * limit) * (right - left);
  const y = score => top + (1 - score) / 2 * (bottom - top);
  const lines = [-1, 0, 1].map(score => `<line x1="${left}" y1="${y(score)}" x2="${right}" y2="${y(score)}" stroke="#cbd5e1"/><text x="${left - 10}" y="${y(score) + 5}" text-anchor="end">${score}</text>`).join('');
  // Split paths at undefined lags instead of silently bridging them.
  let path = '', connected = false;
  const markers = report.lags.map(row => {
    if (row.correlation === null) { connected = false; return `<text x="${x(row.lag_samples)}" y="${bottom + 22}" text-anchor="middle">×<title>${escapeXml(`${row.lag_samples} samples: ${row.status}; ${row.pair_count} pairs`)}</title></text>`; }
    path += `${connected ? 'L' : 'M'}${x(row.lag_samples)},${y(row.correlation)} `; connected = true;
    return `<circle cx="${x(row.lag_samples)}" cy="${y(row.correlation)}" r="3" fill="#1d4ed8"><title>${escapeXml(`${row.lag_samples} samples / ${row.recorded_offset_ms} recorded ms: r=${row.correlation}; ${row.pair_count} pairs`)}</title></circle>`;
  }).join('');
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="430" viewBox="0 0 ${width} 430" role="img" aria-labelledby="title description"><title id="title">Recorded channel-lag association</title><desc id="description">Positive lag compares later response observations. Undefined correlations are marked below the plot. This is not physical latency or causality. Exact values and source lineage are in JSON.</desc><rect width="900" height="430" fill="white"/><g font-family="sans-serif" font-size="13" fill="#172554"><text x="30" y="28">Recorded lag exploration: ${escapeXml(report.reference_channel)} → ${escapeXml(report.response_channel)}</text><text x="30" y="53">Pearson correlation; interval ${escapeXml(report.sample_interval_ms)} recorded ms; minimum ${report.min_pairs} pairs</text>${lines}<path d="${path.trim()}" fill="none" stroke="#2563eb" stroke-width="1.5"/>${markers}<text x="${x(-report.max_lag_samples)}" y="370" text-anchor="middle">${-report.max_lag_samples}</text>${report.max_lag_samples ? `<text x="${x(0)}" y="370" text-anchor="middle">0</text><text x="${x(report.max_lag_samples)}" y="370" text-anchor="middle">${report.max_lag_samples}</text>` : ''}<text x="450" y="392" text-anchor="middle">Lag in samples: positive = later response; overlap and pair counts change with lag</text><text x="450" y="414" text-anchor="middle">Recorded association only; no physical latency, causality or readiness conclusion</text></g></svg>\n`;
}

const usage = 'node scripts/telemetry-lag.mjs INPUT.csv --reference CHANNEL --response CHANNEL --reference-unit UNIT --response-unit UNIT --max-lag-samples N --min-pairs N [--window START_MS END_MS] [--lag-samples SIGNED_N] [--format json|svg|csv]';
function integer(text, name) {
  if (typeof text !== 'string' || !/^-?\d+$/.test(text) || !Number.isSafeInteger(Number(text))) throw new Error(`${name}: expected integer`);
  return Number(text);
}
export function main(args) {
  if (args.length === 1 && args[0] === '--help') return usage + '\n';
  const [input, ...rest] = args;
  if (!input || input.startsWith('--')) throw new Error(usage);
  const options = {}, seen = new Set(); let format = 'json', selected = null;
  const keys = new Map([['--reference', 'reference'], ['--response', 'response'], ['--reference-unit', 'referenceUnit'], ['--response-unit', 'responseUnit'], ['--max-lag-samples', 'maxLagSamples'], ['--min-pairs', 'minPairs']]);
  for (let i = 0; i < rest.length; i++) {
    const key = rest[i];
    if ((!keys.has(key) && !['--window', '--format', '--lag-samples'].includes(key)) || seen.has(key)) throw new Error(`unknown or repeated option: ${key}`);
    seen.add(key);
    const value = rest[++i];
    if (value === undefined || value.startsWith('--')) throw new Error(`missing value for ${key}`);
    if (key === '--window') {
      const end = rest[++i];
      if (end === undefined || end.startsWith('--')) throw new Error('window: missing end timestamp');
      options.window = [value, end];
    } else if (key === '--format') format = value;
    else if (key === '--lag-samples') selected = integer(value, key);
    else options[keys.get(key)] = ['--max-lag-samples', '--min-pairs'].includes(key) ? integer(value, key) : value;
  }
  if (!['json', 'svg', 'csv'].includes(format)) throw new Error('format: expected json, svg or csv');
  if (format === 'csv' && selected === null) throw new Error('CSV requires an explicit --lag-samples selection');
  if (format === 'svg' && selected !== null) throw new Error('SVG shows the full scan; use JSON or CSV for a lag selection');
  const text = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(readFileSync(input));
  const report = scanLag(text, options);
  report.input_file = input;
  if (format === 'csv') return lagCsv(report, selected);
  if (selected !== null) report.selection = selectLag(report, selected);
  return format === 'svg' ? lagSvg(report) : JSON.stringify(report, null, 2) + '\n';
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try { process.stdout.write(main(process.argv.slice(2))); }
  catch (error) { process.stderr.write(JSON.stringify({ error: error.message }) + '\n'); process.exitCode = 2; }
}
