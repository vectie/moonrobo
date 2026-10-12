// Compare actual same-row measurement observations by a caller-declared recorded code.
// No time model, interpolation, robot-state authority, or physical inference.
import { createHash } from 'node:crypto';
import { label, numeric, time, parseRecording } from './telemetry-recording.mjs';
import { validateEdges, histogram } from './telemetry-histogram.mjs';

const anchor = row => ({ sample_index: row.sample_index, source_line: row.source_line, timestamp_ms: row.timestamp_ms });
function sourceBlocks(rows) {
  const blocks = [];
  for (const row of rows) {
    const last = blocks.at(-1);
    if (last && row.sample_index === last.last.sample_index + 1) {
      last.last = anchor(row);
      last.sample_count++;
    } else blocks.push({ first: anchor(row), last: anchor(row), sample_count: 1 });
  }
  return blocks;
}

export function conditionedDistribution(text, { channel, unit, edges, groupBy, groups, window = null }) {
  label(channel, 'channel'); label(unit, 'unit'); label(groupBy, 'group-by');
  if (channel === groupBy) throw new Error('group-by must differ from measured channel');
  validateEdges(edges);
  if (!Array.isArray(groups) || groups.length < 1 || groups.length > 64) throw new Error('groups: declare 1 to 64 numeric codes with labels');
  const byValue = new Map(), labels = new Set();
  const buckets = groups.map(group => {
    if (!group || typeof group.value !== 'number' || !Number.isFinite(group.value)) throw new Error('group code: expected finite number');
    label(group.label, 'group label');
    if (byValue.has(group.value)) throw new Error('groups: duplicate numeric code');
    if (labels.has(group.label)) throw new Error('groups: duplicate label');
    const bucket = { value: group.value, label: group.label, samples: [] };
    byValue.set(group.value, bucket); labels.add(group.label);
    return bucket;
  });
  let bounds = null;
  if (window !== null) {
    if (!Array.isArray(window) || window.length !== 2 || window.some(v => typeof v !== 'string')) throw new Error('window: expected two decimal-string millisecond bounds');
    bounds = window.map(v => time(v, 'window'));
    if (bounds[0] > bounds[1]) throw new Error('window: start exceeds end');
  }
  const recording = parseRecording(text);
  const column = recording.channels.indexOf(channel), codeColumn = recording.channels.indexOf(groupBy);
  if (column < 0) throw new Error(`unknown channel: ${channel}`);
  if (codeColumn < 0) throw new Error(`unknown group-by channel: ${groupBy}`);
  const unknown = [], unknownValues = new Map();
  let selectedCount = 0;
  for (const row of recording.rows) {
    const timestamp = BigInt(row.timestamp_ms);
    if (bounds && (timestamp < bounds[0] || timestamp > bounds[1])) continue;
    selectedCount++;
    const code = row.values[codeColumn], bucket = byValue.get(code);
    if (bucket) bucket.samples.push(row);
    else { unknown.push(row); unknownValues.set(code, (unknownValues.get(code) ?? 0) + 1); }
  }
  const summarize = samples => ({
    sample_count: samples.length,
    fraction_of_window_samples: selectedCount ? samples.length / selectedCount : null,
    ...histogram(samples.map(row => row.values[column]), edges),
    source_blocks: sourceBlocks(samples), samples,
  });
  return {
    format: 'moonrobo.telemetry-conditioned-distribution.v1',
    interpretation: 'same-row recorded-code association; observation counts, not duration, causality, readiness or physical proof',
    source_sha256: createHash('sha256').update(text).digest('hex'),
    timebase: 'milliseconds-as-recorded', channel, unit, group_by: groupBy,
    grouping_rule: 'exact binary64 code equality in the same original row; no hold, interpolation or alignment',
    bin_rule: '[lower,upper), final bin includes upper',
    quantile_method: 'nearest-rank: max(1, ceil(percentile/100 * n)); within group, includes out-of-bin samples',
    fraction_rule: 'bin fractions divide by all observations in that group, including tails; empty group fractions are null',
    source_block_rule: 'consecutive original sample indices only; recording gaps may remain inside a block; no continuity claim',
    export_warning: 'group filtering removes other observations; do not treat neighboring exported rows as continuous recording intervals',
    window: bounds?.map(v => v.toString()) ?? null,
    source_span: [recording.rows[0].timestamp_ms, recording.rows.at(-1).timestamp_ms],
    total_source_samples: recording.rows.length, sample_count: selectedCount,
    channels: recording.channels,
    groups: buckets.map(({ value, label, samples }) => ({ value, label, ...summarize(samples) })),
    undeclared: { codes: [...unknownValues].map(([value, sample_count]) => ({ value, sample_count })), ...summarize(unknown) },
  };
}

// Export helpers accept a successful, unmodified report returned by the API above.
export function selectedGroupCsv(report, selector) {
  if (typeof selector !== 'string') throw new Error('select-group: expected a declared numeric code or undeclared');
  const code = selector === 'undeclared' ? null : numeric(selector.trim(), 'select-group');
  const group = code === null ? report.undeclared : report.groups.find(group => group.value === code);
  if (!group) throw new Error('select-group: code is not declared; use undeclared to inspect unassigned observations');
  if (!group.sample_count) throw new Error('selected group is empty: no reusable CSV samples; inspect JSON or SVG instead');
  return [['timestamp_ms', ...report.channels].join(','), ...group.samples.map(row => [row.timestamp_ms, ...row.values].join(','))].join('\n') + '\n';
}

const escapeXml = value => String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;' })[c]);
export function conditionedSvg(report) {
  const groups = [...report.groups.map(group => ({ ...group, name: `${group.value}: ${group.label}` })), { ...report.undeclared, name: 'Undeclared recorded codes' }];
  const panelHeight = 86 + (report.groups[0].bins.length + 2) * 27;
  const height = 140 + groups.length * panelHeight;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1100 ${height}" role="img" aria-labelledby="title desc">
<title id="title">${escapeXml(report.channel)} observations grouped by ${escapeXml(report.group_by)}</title>
<desc id="desc">Each group uses the same bins and a zero to one hundred percent scale. Percentages divide by that group's observations, including tails. Recorded association is not duration or causality. No physical safety inference.</desc>
<rect width="1100" height="${height}" fill="white"/>
<g font-family="sans-serif" fill="#182b49">
<text x="20" y="30" font-size="20">${escapeXml(report.channel)} (${escapeXml(report.unit)}) by ${escapeXml(report.group_by)}</text>
<text x="20" y="55">${report.sample_count} window observations; ${report.total_source_samples} source observations. Counts, not duration.</text>
${groups.map((group, index) => {
    const top = 90 + index * panelHeight;
    const bars = [{ name: `< ${group.bins[0].lower}`, count: group.underflow }, ...group.bins.map(bin => ({ name: `[${bin.lower}, ${bin.upper}${bin.upper_inclusive ? ']' : ')'}`, count: bin.count })), { name: `> ${group.bins.at(-1).upper}`, count: group.overflow }];
    return `<text x="20" y="${top}" font-size="17">${escapeXml(group.name)}: n=${group.sample_count}</text>
<text x="20" y="${top + 22}" font-size="12">${group.sample_count ? 'Each bar: fraction of this group, 0–100% scale' : 'No observations; fractions and quantiles unavailable'}</text>
${bars.map((bar, i) => `<text x="20" y="${top + 48 + i * 27}" font-size="13">${escapeXml(bar.name)}</text><rect x="390" y="${top + 32 + i * 27}" width="${group.sample_count ? bar.count / group.sample_count * 500 : 0}" height="19" fill="${index === groups.length - 1 ? '#866632' : '#386bc0'}"/><text x="910" y="${top + 48 + i * 27}" font-size="13">${bar.count} (${group.sample_count ? (100 * bar.count / group.sample_count).toFixed(1) + '%' : 'n/a'})</text>`).join('\n')}`;
  }).join('\n')}
<text x="20" y="${height - 18}" font-size="12">Same-row association only. Original source anchors and full processing choices are in JSON.</text>
</g></svg>\n`;
}
