// Offline recorded codes and caller-selected left-hold model; no hardware authority.
import { createHash } from 'node:crypto';
import { label, time, parseRecording } from './telemetry-recording.mjs';

const max = (a, b) => a > b ? a : b;
const min = (a, b) => a < b ? a : b;
const anchor = row => ({ sample_index: row.sample_index, source_line: row.source_line, timestamp_ms: row.timestamp_ms });

export function stateDuration(text, { channel, states, maxGapMs, window = null }) {
  label(channel, 'channel');
  if (!Array.isArray(states) || states.length < 1 || states.length > 64) throw new Error('states: declare 1 to 64 numeric codes with labels');
  const byValue = new Map();
  const summaries = states.map(state => {
    if (!state || typeof state.value !== 'number' || !Number.isFinite(state.value)) throw new Error('state code: expected finite number');
    label(state.label, 'state label');
    if (byValue.has(state.value)) throw new Error('states: duplicate numeric code');
    if ([...byValue.values()].some(s => s.label === state.label)) throw new Error('states: duplicate label');
    const summary = { value: state.value, label: state.label, observation_count: 0, modeled_duration_ms: '0' };
    byValue.set(state.value, summary);
    return summary;
  });
  if (typeof maxGapMs !== 'string') throw new Error('max-gap-ms: required positive Int64 decimal string');
  const gapLimit = time(maxGapMs, 'max-gap-ms');
  if (gapLimit === 0n) throw new Error('max-gap-ms: must be positive');
  let bounds = null;
  if (window !== null) {
    if (!Array.isArray(window) || window.length !== 2 || window.some(v => typeof v !== 'string')) throw new Error('window: expected two decimal-string millisecond bounds');
    bounds = window.map(v => time(v, 'window'));
    if (bounds[0] > bounds[1]) throw new Error('window: start exceeds end');
  }
  const recording = parseRecording(text);
  const column = recording.channels.indexOf(channel);
  if (column < 0) throw new Error(`unknown channel: ${channel}`);
  const first = BigInt(recording.rows[0].timestamp_ms), last = BigInt(recording.rows.at(-1).timestamp_ms);
  const [start, end] = bounds ?? [first, last];
  const selected = recording.rows.filter(row => BigInt(row.timestamp_ms) >= start && BigInt(row.timestamp_ms) <= end);
  let unknownObservations = 0;
  for (const row of selected) {
    const state = byValue.get(row.values[column]);
    if (state) state.observation_count++;
    else unknownObservations++;
  }
  const intervals = [], runs = [], changes = [];
  let modeled = 0n, unknown = 0n, excluded = 0n;
  for (let i = 0; i + 1 < recording.rows.length; i++) {
    const left = recording.rows[i], right = recording.rows[i + 1];
    const t0 = BigInt(left.timestamp_ms), t1 = BigInt(right.timestamp_ms), gap = t1 - t0;
    const value = left.values[column], nextValue = right.values[column];
    const state = byValue.get(value), nextState = byValue.get(nextValue);
    if (value !== nextValue && t1 >= start && t1 <= end) {
      changes.push({
        observed_at_ms: right.timestamp_ms,
        previous: { ...anchor(left), value, state_label: state?.label ?? null },
        current: { ...anchor(right), value: nextValue, state_label: nextState?.label ?? null },
        kind: state && nextState ? 'declared-state-change' : 'unknown-code-boundary',
        continuity: gap > gapLimit ? 'gap-excluded' : 'within-gap-limit',
        adjacent_sample_gap_ms: gap.toString(),
      });
    }
    const a = max(t0, start), b = min(t1, end);
    if (b <= a) continue;
    const duration = b - a;
    // Test the original adjacent gap, never the clipped window length.
    const kind = gap > gapLimit ? 'excluded-recording-gap' : state ? 'modeled-state' : 'unknown-code';
    const interval = {
      interval_index: intervals.length, kind,
      start_ms: a.toString(), end_ms: b.toString(), duration_ms: duration.toString(),
      left: anchor(left), right: anchor(right), adjacent_sample_gap_ms: gap.toString(),
      recorded_value: value, state_label: state?.label ?? null,
    };
    intervals.push(interval);
    if (kind === 'excluded-recording-gap') excluded += duration;
    else if (kind === 'unknown-code') unknown += duration;
    else {
      modeled += duration;
      state.modeled_duration_ms = (BigInt(state.modeled_duration_ms) + duration).toString();
      const previous = runs.at(-1);
      if (previous && previous.state_value === value && previous.end_ms === interval.start_ms && previous.last_interval_index === interval.interval_index - 1) {
        previous.end_ms = interval.end_ms;
        previous.duration_ms = (BigInt(previous.duration_ms) + duration).toString();
        previous.last_interval_index = interval.interval_index;
        previous.right = interval.right;
      } else {
        runs.push({ run_index: runs.length, state_value: value, state_label: state.label,
          start_ms: interval.start_ms, end_ms: interval.end_ms, duration_ms: interval.duration_ms,
          first_interval_index: interval.interval_index, last_interval_index: interval.interval_index,
          left: interval.left, right: interval.right });
      }
    }
  }
  const covered = modeled + unknown + excluded;
  return {
    format: 'moonrobo.telemetry-state-duration.v1',
    interpretation: 'recorded codes plus caller-declared bounded left-hold duration model; not physical state, readiness, or safety proof',
    source_sha256: createHash('sha256').update(text).digest('hex'),
    timebase: 'milliseconds-as-recorded', channel, window: bounds?.map(v => v.toString()) ?? null,
    source_span_ms: [first.toString(), last.toString()], max_gap_ms: gapLimit.toString(),
    model: {
      version: 'bounded-left-hold-v1',
      interval_rule: '[left timestamp,right timestamp); clip to window; never extend before first or beyond last sample',
      gap_rule: 'exclude the entire adjacent interval when original gap > max_gap_ms, even if clipped shorter',
      unknown_rule: 'undeclared left code excludes state duration; over-limit gap takes precedence',
      observation_window: 'inclusive endpoints; predecessor outside window may appear in a change observation or interval anchor',
      change_rule: 'different adjacent recorded codes, reported at right observation; physical change time is unknown',
    },
    total_source_samples: recording.rows.length, observation_count: selected.length,
    unknown_observation_count: unknownObservations,
    coverage: { in_recording_span_ms: covered.toString(), modeled_duration_ms: modeled.toString(),
      unknown_code_duration_ms: unknown.toString(), excluded_gap_duration_ms: excluded.toString(),
      outside_recording_span_ms: (end - start - covered).toString() },
    states: summaries.map(s => ({ ...s, fraction_of_modeled_duration: modeled ? Number(BigInt(s.modeled_duration_ms)) / Number(modeled) : null })),
    changes, intervals, state_runs: runs, channels: recording.channels, samples: selected,
  };
}

const csvCell = value => {
  const text = String(value);
  return /[",\r\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
};

// A review table, intentionally not raw telemetry CSV. Keep the JSON and source.
export function stateRunsCsv(report) {
  const header = ['run_index', 'state_value', 'state_label', 'start_ms', 'end_ms', 'duration_ms',
    'first_interval_index', 'last_interval_index', 'left_sample_index', 'left_source_line', 'left_timestamp_ms',
    'right_sample_index', 'right_source_line', 'right_timestamp_ms', 'source_sha256', 'max_gap_ms', 'duration_model'];
  const rows = report.state_runs.map(run => [run.run_index, run.state_value, run.state_label, run.start_ms, run.end_ms, run.duration_ms,
    run.first_interval_index, run.last_interval_index, run.left.sample_index, run.left.source_line, run.left.timestamp_ms,
    run.right.sample_index, run.right.source_line, run.right.timestamp_ms, report.source_sha256, report.max_gap_ms, report.model.version]);
  return [header, ...rows].map(row => row.map(csvCell).join(',')).join('\n') + '\n';
}

const xml = value => String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;' })[c]);
export function stateDurationSvg(report) {
  const bars = [...report.states.map(s => ({ label: `${s.label} (${s.value})`, duration: s.modeled_duration_ms, color: '#386bc0' })),
    { label: 'Unknown recorded codes', duration: report.coverage.unknown_code_duration_ms, color: '#936900' },
    { label: 'Excluded recording gaps', duration: report.coverage.excluded_gap_duration_ms, color: '#777777' }];
  const maximum = Math.max(1, ...bars.map(b => Number(b.duration)));
  const height = 200 + bars.length * 34;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 ${height}" role="img" aria-labelledby="title desc">
<title id="title">${xml(report.channel)} modeled recorded-state duration</title>
<desc id="desc">Bounded left-hold model in recorded milliseconds. Unknown codes and entire over-limit gaps excluded from state durations. No duration beyond the last sample. No physical readiness inference.</desc>
<rect width="1200" height="${height}" fill="white"/>
<g font-family="sans-serif" fill="#182b49">
<text x="20" y="30" font-size="20">${xml(report.channel)}: modeled duration, not observed physical dwell</text>
<text x="20" y="56">${report.observation_count} observations; ${report.changes.length} recorded value changes; max adjacent gap ${report.max_gap_ms} ms</text>
${bars.map((bar, i) => `<text x="20" y="${92 + i * 34}" font-size="13">${xml(bar.label)}</text><rect x="350" y="${76 + i * 34}" width="${Number(bar.duration) / maximum * 560}" height="22" fill="${bar.color}"/><text x="930" y="${92 + i * 34}">${bar.duration} ms</text>`).join('\n')}
<text x="20" y="${height - 60}">Outside recorded span: ${report.coverage.outside_recording_span_ms} ms. Final observation adds no duration.</text>
<text x="20" y="${height - 36}">Blue: declared-state model. Amber: unknown codes. Gray: excluded gaps. No state is inferred across either exclusion.</text>
<text x="20" y="${height - 12}">Keep JSON for exact source anchors, changes and interval coverage; CSV exports modeled state runs.</text>
</g></svg>\n`;
}
