#!/usr/bin/env node
// Offline recorded-state exploration; never dispatches a device action.
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { label, time, numeric, parseRecording } from './telemetry-recording.mjs';

const MAX_BYTES = 4 * 1024 * 1024;
export function hysteresis(text, { channel, unit, enter, exit, maxGapMs } = {}) {
  label(channel, 'channel'); label(unit, 'unit');
  if (![enter, exit].every(value => typeof value === 'number' && Number.isFinite(value)) || exit >= enter) throw new Error('levels: expected finite exit < enter');
  if (typeof maxGapMs !== 'string') throw new Error('maxGapMs: expected decimal-string milliseconds');
  const gap = time(maxGapMs, 'maxGapMs');
  if (gap === 0n) throw new Error('maxGapMs: must be positive');
  if (typeof text !== 'string' || Buffer.byteLength(text) > MAX_BYTES) throw new Error('recording: expected text of at most 4 MiB');
  const recording = parseRecording(text);
  const column = recording.channels.indexOf(channel);
  if (column < 0) throw new Error('channel is absent from recording');
  let active = false, episode = null, segment = 0;
  const samples = [], episodes = [];
  function close(reason, boundary) {
    if (episode) {
      episode.observed_span_ms = (BigInt(episode.last_timestamp_ms) - BigInt(episode.first_timestamp_ms)).toString();
      episode.end_reason = reason;
      episode.boundary_timestamp_ms = boundary;
      episodes.push(episode);
    }
    episode = null; active = false;
  }
  for (const row of recording.rows) {
    const previous = samples.at(-1);
    const reset = !!previous && BigInt(row.timestamp_ms) - BigInt(previous.timestamp_ms) > gap;
    if (reset) { close('gap', row.timestamp_ms); segment++; }
    const value = row.values[column];
    if (active && value <= exit) close('exit-level', row.timestamp_ms);
    if (!active && value >= enter) {
      active = true;
      episode = { episode_index: episodes.length, segment, first_sample_index: row.sample_index,
        first_timestamp_ms: row.timestamp_ms, last_timestamp_ms: row.timestamp_ms,
        last_sample_index: row.sample_index, sample_count: 0, min: value, max: value };
    }
    if (episode) {
      episode.last_timestamp_ms = row.timestamp_ms; episode.last_sample_index = row.sample_index;
      episode.sample_count++; episode.min = Math.min(episode.min, value); episode.max = Math.max(episode.max, value);
    }
    samples.push({ sample_index: row.sample_index, source_line: row.source_line, timestamp_ms: row.timestamp_ms,
      value, active: active ? 1 : 0, segment, gap_reset: reset });
  }
  close('recording-end', null);
  return { format: 'moonrobo.telemetry-hysteresis.v1', channel, unit, enter, exit, max_gap_ms: gap.toString(),
    source_sha256: createHash('sha256').update(text).digest('hex'),
    interpretation: 'Recorded high-state classifier only; not physical state, safety, readiness, or incident qualification.',
    semantics: 'Start inactive in every segment; enter at value >= enter; exit at value <= exit; retain state between levels. No interpolation or state propagation across gaps.',
    duration_semantics: 'Observed span ends at the last active sample; boundary timestamp is the later exit or gap observation, never an inferred crossing.',
    unit_declaration: 'Caller-supplied source unit label; no conversion or calibration.',
    sample_count: samples.length, segment_count: segment + 1, episode_count: episodes.length, episodes, samples };
}

// Call with an unmodified successful hysteresis() result.
export function hysteresisCsv(report) {
  return 'timestamp_ms,hysteresis_active,hysteresis_segment\n' + report.samples.map(row => `${row.timestamp_ms},${row.active},${row.segment}`).join('\n') + '\n';
}
const usage = 'node scripts/telemetry-hysteresis.mjs INPUT.csv --channel NAME --unit UNIT --enter NUMBER --exit NUMBER --max-gap-ms MS [--format json|csv]';
export function main(args) {
  if (args.length === 1 && args[0] === '--help') return usage + '\n';
  const [input, ...rest] = args;
  if (!input || input.startsWith('--')) throw new Error(usage);
  const options = {}, seen = new Set();
  const keys = new Map([['--channel','channel'], ['--unit','unit'], ['--enter','enter'], ['--exit','exit'], ['--max-gap-ms','maxGapMs'], ['--format','format']]);
  for (let i = 0; i < rest.length; i++) {
    const key = rest[i], value = rest[++i];
    if (!keys.has(key) || seen.has(key)) throw new Error(`unknown or repeated option: ${key}`);
    seen.add(key);
    if (value === undefined || value.startsWith('--')) throw new Error(`missing value for ${key}`);
    options[keys.get(key)] = ['--enter','--exit'].includes(key) ? numeric(value, key) : value;
  }
  const format = options.format ?? 'json';
  if (!['json','csv'].includes(format)) throw new Error('format: expected json or csv');
  const bytes = readFileSync(input);
  if (bytes.length > MAX_BYTES) throw new Error('recording exceeds 4 MiB');
  const text = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes);
  const report = hysteresis(text, options);
  return format === 'csv' ? hysteresisCsv(report) : JSON.stringify(report, null, 2) + '\n';
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try { process.stdout.write(main(process.argv.slice(2))); }
  catch (error) { process.stderr.write(JSON.stringify({ error: error.message }) + '\n'); process.exitCode = 2; }
}
