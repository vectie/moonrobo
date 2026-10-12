#!/usr/bin/env node
// Reassemble explicitly related recorded fragments. Never contact a robot.
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { parseRecording, toCsv } from './telemetry-distribution.mjs';

const maxTime = 9223372036854775807n;
const clockPolicy = 'same-recorded-clock';

function gapLimit(text) {
  if (typeof text !== 'string' || !/^\d+$/.test(text) || BigInt(text) < 1n || BigInt(text) > maxTime) {
    throw new Error('maxGapMs: expected positive Int64 milliseconds as decimal text');
  }
  return BigInt(text);
}

/** Stitch complete same-schema fragments without shifting, interpolating or filling time. */
export function stitch(sources, { clock, overlap, maxGapMs } = {}) {
  if (clock !== clockPolicy) throw new Error('clock: explicitly declare same-recorded-clock');
  if (!['reject', 'require-equal'].includes(overlap)) throw new Error('overlap: explicitly choose reject or require-equal');
  const cutoff = gapLimit(maxGapMs);
  if (!Array.isArray(sources) || sources.length < 2 || sources.length > 64) throw new Error('provide 2 to 64 source fragments');
  const names = new Set();
  // Validate every complete source before processing overlap or ordering.
  const inputs = sources.map((source, index) => {
    if (!source || typeof source.name !== 'string' || !source.name.trim() || /[\x00-\x1f\x7f]/.test(source.name)) throw new Error(`source ${index}: expected printable nonblank name`);
    if (names.has(source.name)) throw new Error(`repeated source name: ${source.name}`);
    names.add(source.name);
    if (typeof source.text !== 'string') throw new Error(`source ${source.name}: expected CSV text`);
    try { return { ...source, recording: parseRecording(source.text) }; }
    catch (error) { throw new Error(`source ${source.name}: ${error.message}`); }
  });
  const channels = inputs[0].recording.channels;
  const rowsByTime = new Map();
  const manifests = [];
  let inputSampleCount = 0;
  for (let index = 0; index < inputs.length; index++) {
    const { name, text, recording } = inputs[index];
    if (recording.channels.length !== channels.length || channels.some(channel => !recording.channels.includes(channel))) {
      throw new Error(`source ${name}: channel set differs from first fragment`);
    }
    const order = channels.map(channel => recording.channels.indexOf(channel));
    manifests.push({
      source_index: index, name, source_sha256: createHash('sha256').update(text).digest('hex'),
      source_channels: recording.channels, sample_count: recording.rows.length,
      first_timestamp_ms: recording.rows[0].timestamp_ms, last_timestamp_ms: recording.rows.at(-1).timestamp_ms,
    });
    inputSampleCount += recording.rows.length;
    for (const row of recording.rows) {
      const values = order.map(column => row.values[column]);
      const ref = { source_index: index, source_sample_index: row.sample_index, source_line: row.source_line };
      const prior = rowsByTime.get(row.timestamp_ms);
      if (prior) {
        if (overlap === 'reject') throw new Error(`overlap at ${row.timestamp_ms} ms: ${name}; policy rejects repeated timestamps`);
        const difference = values.findIndex((value, column) => value !== prior.values[column]);
        if (difference >= 0) throw new Error(`conflicting overlap at ${row.timestamp_ms} ms, channel ${channels[difference]}: ${name}`);
        prior.sources.push(ref);
      } else {
        rowsByTime.set(row.timestamp_ms, { timestamp_ms: row.timestamp_ms, values, sources: [ref] });
      }
    }
  }
  const samples = [...rowsByTime.values()].sort((a, b) => BigInt(a.timestamp_ms) < BigInt(b.timestamp_ms) ? -1 : 1);
  const segments = [], gaps = [];
  for (let index = 0; index < samples.length; index++) {
    const row = samples[index];
    const duration = index ? BigInt(row.timestamp_ms) - BigInt(samples[index - 1].timestamp_ms) : 0n;
    if (index === 0 || duration > cutoff) {
      if (index) gaps.push({
        left_sample_index: index - 1, right_sample_index: index,
        left_timestamp_ms: samples[index - 1].timestamp_ms, right_timestamp_ms: row.timestamp_ms,
        observed_interval_ms: duration.toString(),
      });
      segments.push({ segment_index: segments.length, first_sample_index: index, last_sample_index: index, first_timestamp_ms: row.timestamp_ms, last_timestamp_ms: row.timestamp_ms, sample_count: 0 });
    }
    const segment = segments.at(-1);
    segment.last_sample_index = index; segment.last_timestamp_ms = row.timestamp_ms; segment.sample_count++;
    row.sample_index = index; row.segment_index = segment.segment_index;
  }
  return {
    format: 'moonrobo.telemetry-stitch.v1',
    interpretation: 'recorded fragments only; shared clock, robot, units and calibration are caller assertions, not verified identity',
    clock_policy: clock, overlap_policy: overlap,
    overlap_equality: 'exact numeric equality after finite binary64 CSV parsing; positive and negative zero compare equal',
    max_gap_ms: cutoff.toString(), gap_rule: 'adjacent observed interval strictly greater than max_gap_ms',
    sources: manifests, input_sample_count: inputSampleCount, sample_count: samples.length,
    collapsed_overlap_samples: inputSampleCount - samples.length,
    overlap_timestamp_count: samples.filter(row => row.sources.length > 1).length,
    channels, samples, segments, gaps,
  };
}

// Whole-session or one gap-separated segment CSV uses the established product format.
export function stitchCsv(report, segmentIndex = null) {
  if (segmentIndex !== null && (!Number.isSafeInteger(segmentIndex) || segmentIndex < 0 || segmentIndex >= report.segments.length)) {
    throw new Error('segment: index does not exist in this report');
  }
  const samples = segmentIndex === null ? report.samples : report.samples.filter(row => row.segment_index === segmentIndex);
  return toCsv({ channels: report.channels, samples });
}

const usage = 'node scripts/telemetry-stitch.mjs --input PART.csv --input PART.csv [--input PART.csv ...] --clock same-recorded-clock --overlap reject|require-equal --max-gap-ms MS [--format json|csv] [--segment INDEX]';
export function main(args) {
  if (args.length === 1 && args[0] === '--help') return usage + '\n';
  const paths = [], options = {}, seen = new Set();
  let format = 'json', segmentIndex = null;
  for (let index = 0; index < args.length; index++) {
    const key = args[index];
    if (!['--input', '--clock', '--overlap', '--max-gap-ms', '--format', '--segment'].includes(key) || (key !== '--input' && seen.has(key))) throw new Error(`unknown or repeated option: ${key}`);
    seen.add(key);
    const value = args[++index];
    if (value === undefined || value.startsWith('--')) throw new Error(`missing value for ${key}`);
    if (key === '--input') paths.push(value);
    else if (key === '--format') format = value;
    else if (key === '--segment') {
      if (!/^\d+$/.test(value) || !Number.isSafeInteger(Number(value))) throw new Error('segment: expected nonnegative integer index');
      segmentIndex = Number(value);
    } else options[key === '--max-gap-ms' ? 'maxGapMs' : key.slice(2)] = value;
  }
  if (!['json', 'csv'].includes(format)) throw new Error('format must be json or csv');
  if (segmentIndex !== null && format !== 'csv') throw new Error('segment selection requires --format csv; JSON always describes the complete stitch');
  if (paths.length < 2 || paths.length > 64) throw new Error(usage);
  const sources = paths.map(name => ({ name, text: new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(readFileSync(name)) }));
  const report = stitch(sources, options);
  return format === 'csv' ? stitchCsv(report, segmentIndex) : JSON.stringify(report, null, 2) + '\n';
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try { process.stdout.write(main(process.argv.slice(2))); }
  catch (error) { process.stderr.write(JSON.stringify({ error: error.message }) + '\n'); process.exitCode = 2; }
}
