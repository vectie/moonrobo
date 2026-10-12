import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { stitch, stitchCsv } from './telemetry-stitch.mjs';
import { parseRecording, distribution } from './telemetry-distribution.mjs';

const options = { clock: 'same-recorded-clock', overlap: 'require-equal', maxGapMs: '100' };
const source = (name, text) => ({ name, text });
const fragment = (name, rows) => source(name, `timestamp_ms,load.n,temperature.c\n${rows}\n`);
const a = fragment('a', '1000,1,20\n1100,2,21\n1200,3,22');
const b = source('b', 'timestamp_ms,temperature.c,load.n\n1200,22,3\n1300,23,4\n5000,24,5\n5100,25,6\n');
const c = fragment('c', '5100,6,25\n5200,7,26');

function run(args) {
  return spawnSync(process.execPath, ['scripts/telemetry-stitch.mjs', ...args], { encoding: 'utf8' });
}

const policyArgs = ['--clock', 'same-recorded-clock', '--overlap', 'require-equal', '--max-gap-ms', '100'];

test('rotated files reopen as one chronological recording with every original channel', () => {
  const report = stitch([a, b, c], options);
  assert.deepEqual(report.channels, ['load.n', 'temperature.c']);
  assert.deepEqual(report.samples.map(row => [row.timestamp_ms, ...row.values]), [
    ['1000', 1, 20], ['1100', 2, 21], ['1200', 3, 22], ['1300', 4, 23],
    ['5000', 5, 24], ['5100', 6, 25], ['5200', 7, 26],
  ]);
  assert.equal(report.input_sample_count, 9); assert.equal(report.sample_count, 7);
  assert.equal(report.collapsed_overlap_samples, 2); assert.equal(report.overlap_timestamp_count, 2);
  assert.deepEqual(parseRecording(stitchCsv(report)).rows.map(row => row.values), report.samples.map(row => row.values));
});

test('input order does not set the time origin and first input sets column order', () => {
  const report = stitch([b, c, a], options);
  assert.deepEqual(report.channels, ['temperature.c', 'load.n']);
  assert.deepEqual(report.samples.map(row => row.timestamp_ms), ['1000', '1100', '1200', '1300', '5000', '5100', '5200']);
  assert.deepEqual(report.samples[0].values, [20, 1]);
  assert.deepEqual(report.samples[0].sources, [{ source_index: 2, source_sample_index: 0, source_line: 2 }]);
});

test('all contributing source rows survive as source references, including three-way overlap', () => {
  const duplicate = source('copy', '\r\n timestamp_ms , load.n , temperature.c\r\n\r\n1200,3e0,2.2e1');
  const report = stitch([a, b, duplicate], options);
  assert.equal(report.sources[2].source_sha256, createHash('sha256').update(duplicate.text).digest('hex'));
  assert.deepEqual(report.sources[1].source_channels, ['temperature.c', 'load.n']);
  assert.deepEqual(report.samples[2].sources, [
    { source_index: 0, source_sample_index: 2, source_line: 4 },
    { source_index: 1, source_sample_index: 0, source_line: 2 },
    { source_index: 2, source_sample_index: 0, source_line: 4 },
  ]);
  assert.equal(report.samples.reduce((sum, row) => sum + row.sources.length, 0), report.input_sample_count);
  assert.equal(report.collapsed_overlap_samples, 2); assert.equal(report.overlap_timestamp_count, 1);
});

test('exact timestamps above 2^53 and at Int64 max sort, deduplicate and compute gaps exactly', () => {
  const report = stitch([
    fragment('later', '9007199254740993,2,21\n9223372036854775807,3,22'),
    fragment('earlier', '9007199254740992,1,20\n9007199254740993,2,21'),
  ], { ...options, maxGapMs: '1' });
  assert.deepEqual(report.samples.map(row => row.timestamp_ms), ['9007199254740992', '9007199254740993', '9223372036854775807']);
  assert.equal(report.gaps[0].observed_interval_ms, (9223372036854775807n - 9007199254740993n).toString());
  assert.equal(parseRecording(stitchCsv(report)).rows.at(-1).timestamp_ms, '9223372036854775807');
});

test('gap inspection uses the combined observed timeline without inventing absent samples', () => {
  const report = stitch([a, b, c], options);
  assert.deepEqual(report.gaps, [{ left_sample_index: 3, right_sample_index: 4, left_timestamp_ms: '1300', right_timestamp_ms: '5000', observed_interval_ms: '3700' }]);
  assert.deepEqual(report.segments.map(s => [s.first_timestamp_ms, s.last_timestamp_ms, s.sample_count]), [['1000', '1300', 4], ['5000', '5200', 3]]);
  assert.deepEqual(report.samples.map(row => row.segment_index), [0, 0, 0, 0, 1, 1, 1]);
  // Another real fragment can fill part of a fragment's own gap.
  const filled = stitch([fragment('outer', '0,1,20\n200,3,22'), fragment('inside', '100,2,21')], options);
  assert.equal(filled.gaps.length, 0); assert.equal(filled.sample_count, 3);
});

test('gap-separated segment exports reopen and reanalyze through the existing explorer', () => {
  const report = stitch([a, b, c], options);
  const csv = stitchCsv(report, 1);
  const parsed = parseRecording(csv);
  assert.deepEqual(parsed.rows.map(row => row.timestamp_ms), ['5000', '5100', '5200']);
  const explored = distribution(csv, { channel: 'load.n', unit: 'N', edges: [0, 4, 8] });
  assert.deepEqual(explored.bins.map(bin => bin.count), [0, 3]);
  assert.equal(explored.quantiles.find(q => q.percentile === 50).value, 6);
  assert.throws(() => stitchCsv(report, 2), /index does not exist/);
});

test('disjoint fragments with reject policy preserve all observations and singleton segments', () => {
  const report = stitch([fragment('end', '1000,3,22'), fragment('start', '0,1,20')], { ...options, overlap: 'reject' });
  assert.equal(report.collapsed_overlap_samples, 0);
  assert.deepEqual(report.segments.map(s => s.sample_count), [1, 1]);
  assert.equal(parseRecording(stitchCsv(report, 0)).rows[0].timestamp_ms, '0');
});

test('overlap choices never prefer one conflicting value or silently shift a reset clock', () => {
  assert.throws(() => stitch([a, b], { ...options, overlap: 'reject' }), /overlap at 1200/);
  assert.throws(() => stitch([a, fragment('different', '1200,99,22')], options), /conflicting overlap at 1200 ms, channel load.n/);
  const zero = stitch([fragment('zero', '0,0,20'), fragment('minus-zero', '0,-0,2e1')], options);
  assert.equal(zero.sample_count, 1);
  assert.throws(() => stitch([a, b], { overlap: 'require-equal', maxGapMs: '100' }), /explicitly declare/);
});

test('schema differences and incomplete source rows stop the whole import', () => {
  assert.throws(() => stitch([a, source('changed', 'timestamp_ms,load.n,other\n2000,1,2')], options), /channel set differs/);
  assert.throws(() => stitch([a, source('broken', 'timestamp_ms,load.n,temperature.c\n1300,4,23\n5000,5,')], options), /source broken: line 3/);
  assert.throws(() => stitch([a, source('reset', 'timestamp_ms,load.n,temperature.c\n100,1,20\n0,2,21')], options), /strictly increase/);
  assert.throws(() => stitch([a, a], options), /repeated source name/);
});

test('real CLI generates traceability JSON, whole-session CSV and selected-segment CSV for the product explorer', () => {
  const dir = mkdtempSync(join(tmpdir(), 'robo-stitch-'));
  try {
    const paths = [a, b, c].map((part, i) => { const path = join(dir, `part-${i}.csv`); writeFileSync(path, part.text); return path; });
    const args = [...paths.flatMap(path => ['--input', path]), ...policyArgs];
    const json = run(args);
    assert.equal(json.status, 0, json.stderr); assert.equal(json.stderr, '');
    const jsonPath = join(dir, 'session.json'); writeFileSync(jsonPath, json.stdout);
    assert.equal(JSON.parse(readFileSync(jsonPath, 'utf8')).collapsed_overlap_samples, 2);
    for (const segment of [null, 1]) {
      const stitched = run([...args, '--format', 'csv', ...(segment === null ? [] : ['--segment', String(segment)])]);
      assert.equal(stitched.status, 0, stitched.stderr); assert.equal(stitched.stderr, '');
      const output = join(dir, `stitched-${segment}.csv`); writeFileSync(output, stitched.stdout);
      const explored = spawnSync(process.execPath, ['scripts/telemetry-distribution.mjs', output, '--channel', 'load.n', '--unit', 'N', '--edges', '0,4,8'], { encoding: 'utf8' });
      assert.equal(explored.status, 0, explored.stderr);
      const report = JSON.parse(explored.stdout);
      assert.equal(report.sample_count, segment === null ? 7 : 3);
      assert.deepEqual(report.bins.map(bin => bin.count), segment === null ? [3, 4] : [0, 3]);
    }
    paths.forEach((path, i) => assert.equal(readFileSync(path, 'utf8'), [a, b, c][i].text));
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('CLI reports an overlap conflict atomically and requires an explicit output segment', () => {
  const dir = mkdtempSync(join(tmpdir(), 'robo-stitch-error-'));
  try {
    const first = join(dir, 'first.csv'), second = join(dir, 'second.csv');
    writeFileSync(first, a.text); writeFileSync(second, fragment('different', '1200,9,22').text);
    const args = ['--input', first, '--input', second, ...policyArgs];
    const conflict = run([...args, '--format', 'csv']);
    assert.equal(conflict.status, 2); assert.equal(conflict.stdout, ''); assert.match(JSON.parse(conflict.stderr).error, /conflicting overlap/);
    writeFileSync(second, b.text);
    const wrongFormat = run([...args, '--segment', '0']);
    assert.equal(wrongFormat.status, 2); assert.equal(wrongFormat.stdout, ''); assert.match(JSON.parse(wrongFormat.stderr).error, /requires --format csv/);
    writeFileSync(second, Buffer.from([0xff]));
    const invalidUtf8 = run(args);
    assert.equal(invalidUtf8.status, 2); assert.equal(invalidUtf8.stdout, ''); assert.ok(JSON.parse(invalidUtf8.stderr).error);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('checked-in rotated captures compose directly with the checked-in distribution workflow', () => {
  const parts = ['a', 'b', 'c'].map(part => source(part, readFileSync(`examples/telemetry/rotated-part-${part}.csv`, 'utf8')));
  const report = stitch(parts, options);
  assert.equal(report.sample_count, 7); assert.equal(report.gaps[0].observed_interval_ms, '3700');
  const explored = distribution(stitchCsv(report), { channel: 'load.n', unit: 'N', edges: [0, 4, 8] });
  assert.equal(explored.quantiles.find(q => q.percentile === 50).value, 4);
});
