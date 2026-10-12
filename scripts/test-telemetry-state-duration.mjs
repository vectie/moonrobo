import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { distribution, parseRecording, toCsv } from './telemetry-distribution.mjs';
import { stateDuration, stateRunsCsv, stateDurationSvg } from './telemetry-state-duration.mjs';

const input = readFileSync('examples/telemetry/recorded-states.csv', 'utf8');
const options = { channel: 'mode', states: [{ value: 0, label: 'idle' }, { value: 1, label: 'working' }, { value: 2, label: 'held' }], maxGapMs: '300' };
const durations = report => report.states.map(s => s.modeled_duration_ms);
const csv = rows => 'timestamp_ms,mode\n' + rows.map(r => r.join(',')).join('\n') + '\n';

test('hand-calculated irregular model separates observations, durations, unknowns and whole gaps', () => {
  const r = stateDuration(input, options);
  assert.deepEqual(durations(r), ['400', '400', '100']);
  assert.deepEqual(r.states.map(s => s.observation_count), [3, 3, 2]);
  assert.equal(r.unknown_observation_count, 1);
  assert.deepEqual(r.coverage, { in_recording_span_ms: '2200', modeled_duration_ms: '900', unknown_code_duration_ms: '100', excluded_gap_duration_ms: '1200', outside_recording_span_ms: '0' });
  assert.equal(r.states[0].fraction_of_modeled_duration, 4 / 9);
  assert.equal(r.source_sha256, createHash('sha256').update(input).digest('hex'));
  assert.deepEqual(r.samples.map(s => s.values[1]), [2, 3, 8, 9, 4, 1, 1, 2, 7]);
});

test('merged state runs keep source anchors and split at unknowns, gaps and declared changes', () => {
  const r = stateDuration(input, options);
  assert.deepEqual(r.state_runs.map(run => [run.state_value, run.start_ms, run.end_ms, run.duration_ms]), [
    [0, '1000', '1300', '300'], [1, '1300', '1700', '400'], [2, '3000', '3100', '100'], [0, '3100', '3200', '100']]);
  assert.equal(r.state_runs[0].first_interval_index, 0);
  assert.equal(r.state_runs[0].last_interval_index, 1);
  assert.deepEqual(r.state_runs[0].left, { sample_index: 0, source_line: 2, timestamp_ms: '1000' });
  assert.deepEqual(r.state_runs[0].right, { sample_index: 2, source_line: 4, timestamp_ms: '1300' });
  const split = stateDuration(csv([[0, 0], [10, 0], [1000, 0], [1010, 0], [1020, 9], [1030, 0], [1040, 0]]), { ...options, maxGapMs: '10' });
  assert.deepEqual(split.state_runs.map(run => run.duration_ms), ['10', '20', '10']);
});

test('changes report observed endpoints, unknown boundaries and gaps without asserting exact transition time', () => {
  const r = stateDuration(input, options);
  assert.deepEqual(r.changes.map(c => [c.observed_at_ms, c.kind]), [['1300', 'declared-state-change'], ['1700', 'unknown-code-boundary'], ['1800', 'unknown-code-boundary'], ['3100', 'declared-state-change'], ['3200', 'declared-state-change']]);
  const gap = stateDuration(csv([[0, 0], [1000, 1]]), options);
  assert.equal(gap.changes[0].continuity, 'gap-excluded');
  assert.equal(gap.changes[0].previous.timestamp_ms, '0');
  assert.equal(gap.changes[0].current.timestamp_ms, '1000');
  assert.deepEqual(durations(gap), ['0', '0', '0']);
});

test('window clips intervals using outside anchors and inclusive observations; does not invent samples', () => {
  const r = stateDuration(input, { ...options, window: ['1150', '1350'] });
  assert.deepEqual(durations(r), ['150', '50', '0']);
  assert.equal(r.observation_count, 1);
  assert.deepEqual(r.samples.map(s => s.timestamp_ms), ['1300']);
  assert.equal(r.intervals[0].left.timestamp_ms, '1100');
  assert.equal(r.intervals[1].right.timestamp_ms, '1400');
  assert.equal(r.changes[0].previous.timestamp_ms, '1100');
  const noObservation = stateDuration(input, { ...options, window: ['1150', '1200'] });
  assert.equal(noObservation.observation_count, 0);
  assert.deepEqual(durations(noObservation), ['50', '0', '0']);
});

test('original gap threshold is inclusive and cannot be bypassed by clipping a gap', () => {
  const accepted = stateDuration(csv([[0, 0], [300, 1]]), options);
  assert.deepEqual(durations(accepted), ['300', '0', '0']);
  const clipped = stateDuration(input, { ...options, window: ['1900', '1950'] });
  assert.equal(clipped.coverage.excluded_gap_duration_ms, '50');
  assert.equal(clipped.intervals[0].adjacent_sample_gap_ms, '1200');
  assert.equal(clipped.coverage.modeled_duration_ms, '0');
});

test('singleton, point and outside windows never add duration before first or after final sample', () => {
  const single = stateDuration(csv([[10, 1]]), { ...options, window: ['0', '100'] });
  assert.equal(single.observation_count, 1); assert.deepEqual(single.state_runs, []);
  assert.equal(single.coverage.outside_recording_span_ms, '100');
  assert.ok(single.states.every(s => s.fraction_of_modeled_duration === null));
  const point = stateDuration(input, { ...options, window: ['3200', '3200'] });
  assert.equal(point.observation_count, 1); assert.equal(point.coverage.modeled_duration_ms, '0');
  assert.equal(point.changes[0].observed_at_ms, '3200');
  const beyond = stateDuration(input, { ...options, window: ['3100', '9000'] });
  assert.deepEqual(durations(beyond), ['100', '0', '0']);
  assert.equal(beyond.coverage.outside_recording_span_ms, '5800');
  const before = stateDuration(input, { ...options, window: ['0', '20'] });
  assert.equal(before.coverage.outside_recording_span_ms, '20');
  assert.equal(before.observation_count, 0); assert.deepEqual(before.intervals, []);
});

test('exact Int64 timestamps and durations survive clipping, runs and CSV beyond Number precision', () => {
  const r = stateDuration(csv([['0', 0], ['9007199254740993', 1], ['9223372036854775807', 2]]), { ...options, maxGapMs: '9223372036854775807', window: ['1', '9223372036854775806'] });
  assert.deepEqual(durations(r), ['9007199254740992', '9214364837600034813', '0']);
  assert.equal(r.coverage.in_recording_span_ms, '9223372036854775805');
  assert.match(stateRunsCsv(r), /9007199254740993,9223372036854775806,9214364837600034813/);
});

test('unknown codes stay visible; over-limit unknown intervals count only as gaps', () => {
  const r = stateDuration(csv([[0, 9], [10, 8], [1000, 0]]), { ...options, maxGapMs: '10' });
  assert.equal(r.unknown_observation_count, 2);
  assert.equal(r.coverage.unknown_code_duration_ms, '10');
  assert.equal(r.coverage.excluded_gap_duration_ms, '990');
  assert.deepEqual(r.intervals.map(i => i.kind), ['unknown-code', 'excluded-recording-gap']);
  assert.equal(r.intervals[0].recorded_value, 9);
  assert.deepEqual(r.state_runs, []);
  assert.equal(stateRunsCsv(r).split('\n').length, 2);
});

test('explicit declarations and bound are required; whole source remains validated', () => {
  for (const changes of [{ states: [] }, { states: [{ value: 0, label: '' }] }, { states: [{ value: 0, label: 'x' }, { value: -0, label: 'y' }] }, { states: [{ value: 0, label: 'x' }, { value: 1, label: 'x' }] }, { maxGapMs: undefined }, { maxGapMs: '0' }, { maxGapMs: '1.5' }, { maxGapMs: '9223372036854775808' }, { channel: 'absent' }, { window: ['20', '10'] }]) assert.throws(() => stateDuration(input, { ...options, ...changes }));
  assert.throws(() => stateDuration(input + '9999,0,NaN\n', { ...options, window: ['1000', '1001'] }), /finite/);
  assert.throws(() => stateDuration(input + '3200,0,2\n', options), /strictly increase/);
});

test('CSV run table and SVG carry model semantics and escaped caller labels', () => {
  const r = stateDuration(csv([[0, 0], [10, 1]]), { ...options, states: [{ value: 0, label: 'idle,"quoted"<&>' }, { value: 1, label: 'work' }] });
  assert.match(stateRunsCsv(r), /"idle,""quoted""<&>"/);
  assert.match(stateRunsCsv(r), /source_sha256,max_gap_ms,duration_model/);
  const svg = stateDurationSvg(r);
  assert.match(svg, /&lt;&amp;&gt;/); assert.doesNotMatch(svg, /<\&>/);
  assert.match(svg, /No duration beyond the last sample/);
  assert.match(svg, /Excluded recording gaps/);
  assert.match(svg, /Unknown recorded codes/);
});

test('state workflow shares the existing numeric parser and leaves sample distribution unchanged', () => {
  const parsed = parseRecording(input);
  const r = distribution(input, { channel: 'mode', unit: 'code', edges: [0, 1, 2, 10] });
  assert.equal(r.sample_count, parsed.rows.length);
  assert.deepEqual(r.bins.map(b => b.count), [3, 3, 3]);
  const runObservations = distribution(input, { channel: 'mode', unit: 'recorded-code', edges: [0, 1, 2, 10], window: ['1300', '1700'] });
  assert.deepEqual(runObservations.bins.map(b => b.count), [0, 2, 1]);
  assert.deepEqual(parseRecording(toCsv(runObservations)).rows.map(row => [row.timestamp_ms, row.values[0]]), [['1300', 1], ['1400', 1], ['1700', 9]]);
  assert.equal(stateDuration(input.replaceAll('\n', '\r\n'), options).samples[0].source_line, 2);
});

test('existing distribution CLI produces/reopens all state artifacts without changing source', () => {
  const dir = mkdtempSync(join(tmpdir(), 'robo-state-duration-'));
  try {
    const path = join(dir, 'recorded.csv'); writeFileSync(path, input);
    const args = ['scripts/telemetry-distribution.mjs', path, '--channel', 'mode', '--states', '0=idle,1=working,2=held', '--max-gap-ms', '300'];
    for (const format of ['json', 'csv', 'svg']) {
      const process = spawnSync(globalThis.process.execPath, [...args, '--format', format], { encoding: 'utf8' });
      assert.equal(process.status, 0, process.stderr); assert.equal(process.stderr, '');
      const file = join(dir, `state-report.${format}`); writeFileSync(file, process.stdout);
      const reopened = readFileSync(file, 'utf8');
      if (format === 'json') assert.deepEqual(durations(JSON.parse(reopened)), ['400', '400', '100']);
      if (format === 'svg') assert.match(reopened, /mode modeled recorded-state duration/);
      if (format === 'csv') {
        const rows = reopened.trim().split('\n').map(line => line.split(','));
        assert.equal(rows.length, 5);
        assert.equal(rows[0][5], 'duration_ms');
        assert.equal(rows.slice(1).reduce((sum, row) => sum + BigInt(row[5]), 0n), 900n);
        assert.equal(rows[1][10], '1000');
      }
    }
    assert.equal(readFileSync(path, 'utf8'), input);
    for (const extra of [['--edges', '0,1'], ['--unit', 's'], ['--max-gap-ms', '10'], ['--format', 'bad'], ['--window', '4']]) {
      const r = spawnSync(process.execPath, [...args, ...extra], { encoding: 'utf8' });
      assert.equal(r.status, 2); assert.equal(r.stdout, ''); assert.ok(JSON.parse(r.stderr).error);
    }
    writeFileSync(path, Buffer.from([0xff]));
    const invalid = spawnSync(process.execPath, args, { encoding: 'utf8' });
    assert.equal(invalid.status, 2); assert.equal(invalid.stdout, '');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
