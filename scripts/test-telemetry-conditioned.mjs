import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { conditionedDistribution, conditionedSvg, selectedGroupCsv } from './telemetry-conditioned.mjs';
import { distribution, parseRecording } from './telemetry-distribution.mjs';

const fixture = 'examples/telemetry/state-conditioned-load.csv';
const input = readFileSync(fixture, 'utf8');
const options = { channel: 'load.n', unit: 'N', edges: [0, 3, 6, 10], groupBy: 'mode', groups: [{ value: 0, label: 'idle' }, { value: 1, label: 'working' }, { value: 2, label: 'held' }, { value: 3, label: 'maintenance' }] };
const run = (text = input, overrides = {}) => conditionedDistribution(text, { ...options, ...overrides });
const args = ['scripts/telemetry-distribution.mjs', fixture, '--channel', 'load.n', '--unit', 'N', '--edges', '0,3,6,10', '--group-by', 'mode', '--groups', '0=idle,1=working,2=held,3=maintenance'];
const cli = (extra = [], base = args) => spawnSync(process.execPath, [...base, ...extra], { encoding: 'utf8' });

test('operator compares hand-calculated same-row load distributions across repeated modes', () => {
  const report = run();
  assert.equal(report.format, 'moonrobo.telemetry-conditioned-distribution.v1');
  assert.equal(report.sample_count, 12);
  assert.deepEqual(report.groups.map(g => g.sample_count), [4, 5, 1, 0]);
  assert.deepEqual(report.groups.map(g => g.bins.map(b => b.count)), [[4, 0, 0], [0, 1, 3], [0, 1, 0], [0, 0, 0]]);
  assert.deepEqual(report.groups[1].quantiles.map(q => q.value), [4, 6, 8, 10, 12, 12, 12]);
  assert.deepEqual(report.groups[0].quantiles.map(q => q.value), [0, 0, 1, 2, 2, 2, 2]);
  assert.equal(report.groups[1].overflow, 1);
  assert.equal(report.groups[1].bins[2].fraction_of_selected_samples, 3 / 5);
  assert.equal(report.groups[1].fraction_of_window_samples, 5 / 12);
  assert.equal(report.groups[0].bins[0].fraction_of_selected_samples, 1);
});

test('undeclared codes remain visible with their own distributions and exact observations', () => {
  const report = run(input.replace('9300,9,9', '9300,8,9'));
  assert.deepEqual(report.undeclared.codes, [{ value: 9, sample_count: 1 }, { value: 8, sample_count: 1 }]);
  assert.equal(report.undeclared.underflow, 1);
  assert.deepEqual(report.undeclared.bins.map(b => b.count), [0, 0, 1]);
  assert.deepEqual(report.undeclared.samples.map(s => s.sample_index), [6, 9]);
  assert.equal(report.groups.reduce((n, group) => n + group.sample_count, report.undeclared.sample_count), report.sample_count);
  const all = [...report.groups.flatMap(g => g.samples), ...report.undeclared.samples].sort((a, b) => a.sample_index - b.sample_index);
  assert.deepEqual(all, parseRecording(input.replace('9300,9,9', '9300,8,9')).rows);
});

test('shared edges partition every group including boundary observations and both tails', () => {
  const report = run();
  const whole = distribution(input, options);
  for (let i = 0; i < whole.bins.length; i++) assert.equal([...report.groups, report.undeclared].reduce((n, g) => n + g.bins[i].count, 0), whole.bins[i].count);
  assert.equal([...report.groups, report.undeclared].reduce((n, g) => n + g.underflow, 0), whole.underflow);
  assert.equal([...report.groups, report.undeclared].reduce((n, g) => n + g.overflow, 0), whole.overflow);
});

test('absent declared states and empty windows do not fabricate measurements or fractions', () => {
  const report = run();
  assert.ok(report.groups[3].quantiles.every(q => q.value === null));
  assert.ok(report.groups[3].bins.every(b => b.fraction_of_selected_samples === null));
  assert.equal(report.groups[3].fraction_of_window_samples, 0);
  assert.deepEqual(report.groups[3].source_blocks, []);
  const empty = run(input, { window: ['1500', '1600'] });
  assert.equal(empty.sample_count, 0);
  assert.ok([...empty.groups, empty.undeclared].every(g => g.fraction_of_window_samples === null));
  assert.throws(() => selectedGroupCsv(report, '3'), /empty/);
  assert.throws(() => selectedGroupCsv(empty, 'undeclared'), /empty/);
});

test('window selection and source lineage preserve inclusive Int64 timestamps and physical lines', () => {
  const source = '\ufefftimestamp_ms,mode,load.n\r\n9007199254740992,0,1\r\n\r\n9007199254740993,1,2\r\n9223372036854775807,1,6';
  const report = run(source, { window: ['9007199254740993', '9223372036854775807'] });
  const rows = report.groups[1].samples;
  assert.deepEqual(rows.map(s => s.timestamp_ms), ['9007199254740993', '9223372036854775807']);
  assert.deepEqual(rows.map(s => s.source_line), [4, 5]);
  assert.deepEqual(rows.map(s => s.sample_index), [1, 2]);
  assert.equal(report.source_sha256, createHash('sha256').update(source).digest('hex'));
  assert.deepEqual(parseRecording(selectedGroupCsv(report, '1')).rows.map(s => s.timestamp_ms), rows.map(s => s.timestamp_ms));
});

test('sample-index blocks expose removed observations without claiming temporal continuity', () => {
  const report = run();
  assert.deepEqual(report.groups[1].source_blocks.map(b => [b.first.sample_index, b.last.sample_index, b.sample_count]), [[2, 3, 2], [5, 5, 1], [7, 7, 1], [11, 11, 1]]);
  const largeGap = run('timestamp_ms,mode,load.n\n0,1,2\n9000,1,3');
  assert.equal(largeGap.groups[1].source_blocks.length, 1);
  assert.match(largeGap.source_block_rule, /recording gaps may remain/);
  assert.match(largeGap.export_warning, /do not treat neighboring exported rows as continuous/);
});

test('irregular cadence changes neither group weights nor same-row membership', () => {
  const regular = input.split('\n').map((line, index) => index && line ? line.replace(/^\d+/, String(index)) : line).join('\n');
  const before = run(), after = run(regular);
  for (let i = 0; i < before.groups.length; i++) {
    assert.deepEqual(before.groups[i].bins, after.groups[i].bins);
    assert.deepEqual(before.groups[i].quantiles, after.groups[i].quantiles);
    assert.equal(before.groups[i].sample_count, after.groups[i].sample_count);
  }
});

test('selected working observations reopen with every original channel and reproduce that distribution', () => {
  const report = run();
  const csv = selectedGroupCsv(report, '1');
  const parsed = parseRecording(csv);
  assert.deepEqual(parsed.channels, report.channels);
  assert.deepEqual(parsed.rows.map(row => [row.timestamp_ms, row.values]), report.groups[1].samples.map(row => [row.timestamp_ms, row.values]));
  assert.deepEqual(distribution(csv, options).bins, report.groups[1].bins);
  assert.deepEqual(distribution(csv, options).quantiles, report.groups[1].quantiles);
  assert.equal(parseRecording(selectedGroupCsv(report, 'undeclared')).rows.length, 2);
  assert.throws(() => selectedGroupCsv(report, '9'), /not declared/);
  assert.throws(() => selectedGroupCsv(report, 'working'), /finite decimal/);
});

test('group declaration order is stable and numeric equality is explicit', () => {
  const report = run('timestamp_ms,mode,load.n\n0,-0,1\n1,1e0,2', { groups: [{ value: 1, label: 'working' }, { value: 0, label: 'idle' }] });
  assert.deepEqual(report.groups.map(g => g.value), [1, 0]);
  assert.deepEqual(report.groups.map(g => g.samples[0].sample_index), [1, 0]);
  assert.match(report.grouping_rule, /exact binary64/);
  assert.throws(() => run(input, { groups: [{ value: 0, label: 'a' }, { value: -0, label: 'b' }] }), /duplicate numeric code/);
});

test('group comparison validates the complete source before filtering or grouping', () => {
  assert.throws(() => run(input + '9600,9,,1', { window: ['1000', '1100'] }), /finite decimal/);
  assert.throws(() => run(input.replace('9500,1,10,53', '9500,1,10,NaN'), { window: ['1000', '1100'] }), /finite decimal/);
  assert.throws(() => run(input.replace('9500,1', '9400,1')), /strictly increase/);
  assert.throws(() => run('timestamp_ms,mode,load.n\n0,0,"1"'), /quoted/);
});

test('measurement units, distinct grouping channel, bin edges and code declarations are required', () => {
  assert.throws(() => run(input, { unit: undefined }), /unit/);
  assert.throws(() => run(input, { groupBy: 'load.n' }), /must differ/);
  assert.throws(() => run(input, { groupBy: 'not-there' }), /unknown group-by/);
  assert.throws(() => run(input, { edges: [0, 0] }), /strictly increasing/);
  assert.throws(() => run(input, { groups: [] }), /declare/);
  assert.throws(() => run(input, { groups: [{ value: NaN, label: 'a' }] }), /finite number/);
  assert.throws(() => run(input, { groups: [{ value: 0, label: 'a' }, { value: 1, label: 'a' }] }), /duplicate label/);
  assert.throws(() => run(input, { window: ['1100', '1000'] }), /start exceeds/);
});

test('comparison SVG exposes group denominators, empty states and escaped supplied labels', () => {
  const report = run(input, { unit: '<N&>', groups: [{ value: 0, label: '<idle&>' }, { value: 7, label: 'absent' }] });
  const svg = conditionedSvg(report);
  assert.match(svg, /&lt;idle&amp;&gt;: n=4/);
  assert.match(svg, /&lt;N&amp;&gt;/);
  assert.doesNotMatch(svg, /<idle/);
  assert.match(svg, /No observations; fractions and quantiles unavailable/);
  assert.match(svg, /Undeclared recorded codes: n=8/);
  assert.match(svg, /100\.0%/);
  assert.match(svg, /Counts, not duration/);
  assert.match(svg, /zero to one hundred percent scale/);
});

test('actual existing CLI produces JSON/SVG and explicitly selected CSV for reanalysis', () => {
  const directory = mkdtempSync(join(tmpdir(), 'robo-conditioned-'));
  try {
    const before = readFileSync(fixture);
    for (const format of ['json', 'svg', 'csv']) {
      const result = cli(['--format', format, ...(format === 'csv' ? ['--select-group', '1'] : [])]);
      assert.equal(result.status, 0, result.stderr); assert.equal(result.stderr, '');
      const output = join(directory, `working.${format}`); writeFileSync(output, result.stdout);
      if (format === 'json') assert.equal(JSON.parse(readFileSync(output, 'utf8')).groups[1].sample_count, 5);
      if (format === 'svg') assert.match(readFileSync(output, 'utf8'), /working: n=5/);
      if (format === 'csv') {
        const reanalysis = cli([], ['scripts/telemetry-distribution.mjs', output, '--channel', 'load.n', '--unit', 'N', '--edges', '0,3,6,10']);
        assert.equal(reanalysis.status, 0, reanalysis.stderr);
        assert.deepEqual(JSON.parse(reanalysis.stdout).bins, run().groups[1].bins);
      }
    }
    assert.deepEqual(readFileSync(fixture), before);
    const undeclared = cli(['--format', 'csv', '--select-group', 'undeclared']);
    assert.equal(undeclared.status, 0, undeclared.stderr);
    assert.equal(parseRecording(undeclared.stdout).rows.length, 2);
  } finally { rmSync(directory, { recursive: true, force: true }); }
});

test('CLI rejects ambiguous exports and mixed duration/comparison recipes with no partial stdout', () => {
  for (const extra of [['--format', 'csv'], ['--select-group', '1'], ['--format', 'csv', '--select-group', '3'], ['--max-gap-ms', '300'], ['--states', '0=idle'], ['--group-by', 'mode']]) {
    const result = cli(extra);
    assert.equal(result.status, 2); assert.equal(result.stdout, ''); assert.ok(JSON.parse(result.stderr).error);
  }
  const help = cli([], ['scripts/telemetry-distribution.mjs', '--help']);
  assert.equal(help.status, 0); assert.match(help.stdout, /--group-by/);
});

test('CLI hashes unchanged valid UTF-8 bytes and rejects malformed bytes', () => {
  const directory = mkdtempSync(join(tmpdir(), 'robo-conditioned-bytes-'));
  try {
    const path = join(directory, 'input.csv');
    const bytes = Buffer.from('\ufeff' + input.replaceAll('\n', '\r\n'));
    writeFileSync(path, bytes);
    const command = [...args]; command[1] = path;
    const valid = cli([], command);
    assert.equal(valid.status, 0, valid.stderr);
    assert.equal(JSON.parse(valid.stdout).source_sha256, createHash('sha256').update(bytes).digest('hex'));
    writeFileSync(path, Buffer.from([0xff]));
    const invalid = cli([], command);
    assert.equal(invalid.status, 2); assert.equal(invalid.stdout, '');
  } finally { rmSync(directory, { recursive: true, force: true }); }
});
