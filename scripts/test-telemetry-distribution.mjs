import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { distribution, parseRecording, toCsv, toSvg } from './telemetry-distribution.mjs';

const input = 'timestamp_ms,load,other\n1000,-1,10\n1001,0,20\n1002,1,30\n\n1003,2,40\n9000,3,50\n9001,4,60\n9002,5,70\n';
const recipe = { channel: 'load', unit: 'N', edges: [0, 2, 4] };

test('explicit bins include internal boundary on right, final endpoint, underflow and overflow', () => {
  const r = distribution(input, recipe);
  assert.deepEqual(r.bins.map(b => b.count), [2, 3]);
  assert.equal(r.underflow, 1); assert.equal(r.overflow, 1);
  assert.equal(r.sample_count, 7);
  assert.equal(r.bins[0].fraction_of_selected_samples, 2 / 7);
  assert.deepEqual(r.quantiles.map(q => q.value), [-1, 0, 2, 4, 5, 5, 5]);
  assert.equal(r.source_sha256, createHash('sha256').update(input).digest('hex'));
  assert.equal(r.samples[3].source_line, 6);
  assert.equal(r.samples[3].sample_index, 3);
});

test('irregular gaps do not give samples extra weight or create inferred observations', () => {
  const r = distribution(input, recipe);
  const regular = distribution(input.replace('9000', '1004').replace('9001', '1005').replace('9002', '1006'), recipe);
  assert.deepEqual(r.bins, regular.bins); assert.deepEqual(r.quantiles, regular.quantiles);
});

test('inclusive Int64 window beyond Number safe range preserves timestamps and source positions', () => {
  const large = 'timestamp_ms,load\n9007199254740992,1\n9007199254740993,2\n9223372036854775807,3\n';
  const r = distribution(large, { ...recipe, window: ['9007199254740993', '9223372036854775807'] });
  assert.deepEqual(r.samples.map(s => s.timestamp_ms), ['9007199254740993', '9223372036854775807']);
  assert.deepEqual(r.samples.map(s => s.sample_index), [1, 2]);
  assert.equal(parseRecording(toCsv(r)).rows[1].timestamp_ms, '9223372036854775807');
});

test('empty and singleton windows have explicit distribution semantics', () => {
  const empty = distribution(input, { ...recipe, window: ['20', '30'] });
  assert.equal(empty.sample_count, 0); assert.equal(empty.bins[0].fraction_of_selected_samples, null);
  assert.ok(empty.quantiles.every(q => q.value === null));
  assert.match(toSvg(empty), /0 selected samples/);
  const one = distribution(input, { ...recipe, window: ['1002', '1002'] });
  assert.ok(one.quantiles.every(q => q.value === 1));
});

test('reusable window CSV retains every channel and numeric sample', () => {
  const r = distribution(input, { ...recipe, window: ['1002', '9000'] });
  const parsed = parseRecording(toCsv(r));
  assert.deepEqual(parsed.channels, ['load', 'other']);
  assert.deepEqual(parsed.rows.map(s => [s.timestamp_ms, s.values]), [['1002', [1, 30]], ['1003', [2, 40]], ['9000', [3, 50]]]);
  assert.deepEqual(distribution(toCsv(r), recipe).bins, r.bins);
});

test('whole recording validation never conceals missing values outside a window', () => {
  for (const bad of ['10000,,1', '10000,2,NaN', '10000,2', '1000,2,1', '9223372036854775808,2,1']) {
    assert.throws(() => distribution(input + bad, { ...recipe, window: ['1001', '1002'] }));
  }
  assert.throws(() => distribution('timestamp_ms,load,load\n0,1,2', recipe), /duplicate/);
  assert.throws(() => distribution('timestamp_ms,load\n0,"1"', recipe), /quoted/);
});

test('edges, units, channels and windows must be explicit and valid', () => {
  for (const edges of [[], [1], [0, 0], [2, 1], [0, Infinity], ['0', 1]]) assert.throws(() => distribution(input, { ...recipe, edges }));
  assert.throws(() => distribution(input, { ...recipe, channel: 'missing' }), /unknown channel/);
  assert.throws(() => distribution(input, { ...recipe, unit: '' }), /unit/);
  assert.throws(() => distribution(input, { ...recipe, window: ['2', '1'] }), /start exceeds/);
});

test('CRLF, scientific values, blank lines and no final newline import without filling', () => {
  const r = distribution('\r\n timestamp_ms , load \r\n0,-1e-2\r\n\r\n1,+.5', { ...recipe, edges: [-1, 0, 1] });
  assert.deepEqual(r.bins.map(b => b.count), [1, 1]);
  assert.deepEqual(r.samples.map(s => s.source_line), [3, 5]);
});

test('portable SVG escapes source-controlled labels and states count semantics', () => {
  const r = distribution('timestamp_ms,<sensor&>\n0,1\n', { channel: '<sensor&>', unit: '<N&>', edges: [0, 2] });
  const svg = toSvg(r);
  assert.ok(svg.startsWith('<svg ')); assert.match(svg, /&lt;sensor&amp;&gt;/);
  assert.doesNotMatch(svg, /<sensor/); assert.match(svg, /Counts, not duration/);
  assert.match(svg, /Underflow and overflow included/);
});

test('actual CLI writes/reopens JSON, SVG and reusable CSV without touching source', () => {
  const dir = mkdtempSync(join(tmpdir(), 'robo-distribution-'));
  try {
    const path = join(dir, 'recorded.csv'); writeFileSync(path, input);
    const args = ['scripts/telemetry-distribution.mjs', path, '--channel', 'load', '--unit', 'N', '--edges', '0,2,4'];
    for (const format of ['json', 'svg', 'csv']) {
      const result = spawnSync(process.execPath, [...args, '--format', format], { encoding: 'utf8' });
      assert.equal(result.status, 0, result.stderr); assert.equal(result.stderr, '');
      const output = join(dir, `report.${format}`); writeFileSync(output, result.stdout);
      const reopened = readFileSync(output, 'utf8');
      if (format === 'json') assert.equal(JSON.parse(reopened).samples.length, 7);
      if (format === 'svg') assert.match(reopened, /<title id="title">load/);
      if (format === 'csv') assert.deepEqual(parseRecording(reopened).rows.map(r => r.values), parseRecording(input).rows.map(r => r.values));
    }
    assert.equal(readFileSync(path, 'utf8'), input);
    for (const extra of [['--window', '2', '1'], ['--unit', 'N'], ['--format', 'bad'], ['--window', '2', '3', '--format', 'csv']]) {
      const result = spawnSync(process.execPath, [...args, ...extra], { encoding: 'utf8' });
      assert.equal(result.status, 2); assert.equal(result.stdout, ''); assert.ok(JSON.parse(result.stderr).error);
    }
    writeFileSync(path, Buffer.from([0xff]));
    const invalidUtf8 = spawnSync(process.execPath, args, { encoding: 'utf8' });
    assert.equal(invalidUtf8.status, 2); assert.equal(invalidUtf8.stdout, '');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('existing product synthetic telemetry recording is directly consumable', () => {
  const text = readFileSync('examples/telemetry/joints.csv', 'utf8');
  const parsed = parseRecording(text);
  const r = distribution(text, { channel: parsed.channels[0], unit: 'caller-declared', edges: [-10, 0, 10] });
  assert.equal(r.sample_count, parsed.rows.length);
  assert.deepEqual(parseRecording(toCsv(r)).channels, parsed.channels);
});
