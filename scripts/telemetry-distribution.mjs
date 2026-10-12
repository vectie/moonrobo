#!/usr/bin/env node
// Recorded-data inspection only. No device, provider or MoonData writes.
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';

import { numeric, time, label, parseRecording } from './telemetry-recording.mjs';
export { parseRecording } from './telemetry-recording.mjs';
import { stateDuration, stateRunsCsv, stateDurationSvg } from './telemetry-state-duration.mjs';
import { validateEdges, histogram } from './telemetry-histogram.mjs';
import { conditionedDistribution, conditionedSvg, selectedGroupCsv } from './telemetry-conditioned.mjs';

export function distribution(text, { channel, unit, edges, window = null }) {
  label(channel, 'channel');
  label(unit, 'unit');
  validateEdges(edges);
  let bounds = null;
  if (window !== null) {
    if (!Array.isArray(window) || window.length !== 2 || window.some(v => typeof v !== 'string')) throw new Error('window: expected two decimal-string millisecond bounds');
    bounds = window.map(v => time(v, 'window'));
    if (bounds[0] > bounds[1]) throw new Error('window: start exceeds end');
  }
  const recording = parseRecording(text);
  const selectedChannel = recording.channels.indexOf(channel);
  if (selectedChannel < 0) throw new Error(`unknown channel: ${channel}`);
  const rows = recording.rows.filter(row => !bounds || (BigInt(row.timestamp_ms) >= bounds[0] && BigInt(row.timestamp_ms) <= bounds[1]));
  const summary = histogram(rows.map(row => row.values[selectedChannel]), edges);
  return {
    format: 'moonrobo.telemetry-distribution.v1',
    interpretation: 'sample-count distribution; not duration, probability of safety, or physical proof',
    source_sha256: createHash('sha256').update(text).digest('hex'),
    timebase: 'milliseconds-as-recorded', channel, unit,
    window: bounds?.map(v => v.toString()) ?? null,
    total_source_samples: recording.rows.length, sample_count: rows.length,
    bin_rule: '[lower,upper), final bin includes upper',
    quantile_method: 'nearest-rank: max(1, ceil(percentile/100 * n)); includes out-of-bin samples',
    ...summary, channels: recording.channels, samples: rows,
  };
}

export function toCsv(report) {
  return [['timestamp_ms', ...report.channels].join(','), ...report.samples.map(row => [row.timestamp_ms, ...row.values].join(','))].join('\n') + '\n';
}
const escapeXml = value => String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;' })[c]);
export function toSvg(report) {
  const bars = [
    { name: `< ${report.bins[0].lower}`, count: report.underflow },
    ...report.bins.map(bin => ({ name: `[${bin.lower}, ${bin.upper}${bin.upper_inclusive ? ']' : ')'}`, count: bin.count })),
    { name: `> ${report.bins.at(-1).upper}`, count: report.overflow },
  ];
  const maximum = Math.max(1, ...bars.map(bin => bin.count));
  const height = 150 + bars.length * 32;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1100 ${height}" role="img" aria-labelledby="title desc">
<title id="title">${escapeXml(report.channel)} recorded sample distribution</title>
<desc id="desc">Explicit value bins. Bar width represents sample count, not elapsed time. Underflow and overflow included. No physical safety inference.</desc>
<rect width="1100" height="${height}" fill="white"/>
<g font-family="sans-serif" fill="#182b49">
<text x="20" y="30" font-size="20">${escapeXml(report.channel)} (${escapeXml(report.unit)})</text>
<text x="20" y="57">${report.sample_count} selected samples; ${report.total_source_samples} source samples. Counts, not duration.</text>
${bars.map((bar, i) => `<text x="20" y="${92 + i * 32}" font-size="13">${escapeXml(bar.name)}</text><rect x="400" y="${76 + i * 32}" width="${bar.count / maximum * 600}" height="22" fill="#386bc0"/><text x="1020" y="${92 + i * 32}">${bar.count}</text>`).join('\n')}
<text x="20" y="${height - 18}" font-size="12">Offline observations only. Quantiles and exact source mapping are in the JSON report.</text>
</g></svg>\n`;
}

const usage = [
  'node scripts/telemetry-distribution.mjs INPUT.csv --channel NAME --unit UNIT --edges E0,E1,... [--window START_MS END_MS] [--format json|svg|csv]',
  '  Add --group-by CHANNEL --groups CODE=LABEL,... to compare a measured channel by recorded code; group CSV also requires --select-group CODE|undeclared.',
  '  Or replace --unit/--edges with --states CODE=LABEL,... --max-gap-ms MS for recorded-state duration modeling (cannot combine with group comparison).',
].join('\n');
export function main(args) {
  if (args.length === 1 && args[0] === '--help') return usage + '\n';
  if (!args.length || args[0].startsWith('--')) throw new Error(usage);
  const [input, ...rest] = args;
  const options = {}, seen = new Set();
  let format = 'json';
  for (let i = 0; i < rest.length; i++) {
    const key = rest[i];
    if (!['--channel', '--unit', '--edges', '--states', '--max-gap-ms', '--window', '--format', '--group-by', '--groups', '--select-group'].includes(key) || seen.has(key)) throw new Error(`unknown or repeated option: ${key}`);
    seen.add(key);
    const value = rest[++i];
    if (value === undefined) throw new Error(`missing value for ${key}`);
    if (key === '--format') format = value;
    else if (key === '--edges') options.edges = value.split(',').map(v => numeric(v.trim(), 'edges'));
    else if (key === '--states' || key === '--groups') options[key === '--states' ? 'states' : 'groups'] = value.split(',').map(entry => {
      const equals = entry.indexOf('=');
      if (equals < 1) throw new Error(`${key.slice(2)}: expected CODE=LABEL,...`);
      return { value: numeric(entry.slice(0, equals).trim(), `${key.slice(2)} code`), label: entry.slice(equals + 1).trim() };
    });
    else if (key === '--max-gap-ms') options.maxGapMs = value;
    else if (key === '--group-by') options.groupBy = value;
    else if (key === '--select-group') options.selectGroup = value;
    else if (key === '--window') options.window = [value, rest[++i]];
    else options[key.slice(2)] = value;
  }
  if (!['json', 'svg', 'csv'].includes(format)) throw new Error('format must be json, svg or csv');
  // Decode strictly: never hash replacement characters as if they were raw capture bytes.
  const text = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(readFileSync(input));
  if (seen.has('--group-by') || seen.has('--groups') || seen.has('--select-group')) {
    if (seen.has('--states') || seen.has('--max-gap-ms')) throw new Error('group comparison does not accept state-duration options');
    if (format !== 'csv' && seen.has('--select-group')) throw new Error('select-group requires format csv; JSON and SVG compare all groups');
    if (format === 'csv' && !seen.has('--select-group')) throw new Error('group CSV requires explicit select-group code or undeclared');
    const report = conditionedDistribution(text, options);
    return format === 'svg' ? conditionedSvg(report) : format === 'csv' ? selectedGroupCsv(report, options.selectGroup) : JSON.stringify(report, null, 2) + '\n';
  }
  if (seen.has('--states') || seen.has('--max-gap-ms')) {
    if (seen.has('--edges') || seen.has('--unit')) throw new Error('states mode does not accept edges or unit; labels are caller-declared states');
    const report = stateDuration(text, options);
    return format === 'svg' ? stateDurationSvg(report) : format === 'csv' ? stateRunsCsv(report) : JSON.stringify(report, null, 2) + '\n';
  }
  const report = distribution(text, options);
  if (format === 'csv' && !report.sample_count) throw new Error('empty window: no reusable CSV samples; inspect JSON or SVG instead');
  return format === 'svg' ? toSvg(report) : format === 'csv' ? toCsv(report) : JSON.stringify(report, null, 2) + '\n';
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try { process.stdout.write(main(process.argv.slice(2))); }
  catch (error) { process.stderr.write(JSON.stringify({ error: error.message }) + '\n'); process.exitCode = 2; }
}
