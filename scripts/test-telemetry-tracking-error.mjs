import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { trackingError, trackingErrorCsv } from './telemetry-tracking-error.mjs';
import { parseRecording } from './telemetry-recording.mjs';
import { distribution } from './telemetry-distribution.mjs';

const fixture = 'examples/telemetry/tracking-error.csv';
const source = readFileSync(fixture, 'utf8');
const options = { requested: 'requested.n', measured: 'measured.n', commonUnit: 'N' };
const config = { requested: 'r', measured: 'm', commonUnit: 'caller-declared' };
const csv = (requested, measured) => 'timestamp_ms,r,m\n' + requested.map((value, i) => `${i},${value},${measured[i]}`).join('\n') + '\n';
const near = (actual, expected) => assert.ok(Math.abs(actual - expected) <= Math.max(Number.MIN_VALUE, Math.abs(expected) * 1e-14), `${actual} != ${expected}`);
const hash = text => createHash('sha256').update(text).digest('hex');
const run = args => spawnSync(process.execPath, ['scripts/telemetry-tracking-error.mjs', ...args], { encoding: 'utf8' });
const argumentsFor = input => [input, '--requested', options.requested, '--measured', options.measured, '--common-unit', options.commonUnit];

test('hand-calculated same-row differences include sign, bias, MAE, RMS and maximum', () => {
  const report = trackingError(source, options);
  assert.equal(report.format, 'moonrobo.telemetry-tracking-error.v1');
  assert.deepEqual(report.samples.map(row => row.error), [1, -2, 0, 3]);
  near(report.bias, 0.5); near(report.mae, 1.5); near(report.rmse, Math.sqrt(3.5));
  assert.equal(report.max_abs_error, 3);
  assert.equal(report.sample_count, 4);
  assert.equal(report.source_sha256, hash(source));
  assert.deepEqual(report.samples.map(row => row.requested_value), [10, 12, 14, 16]);
  assert.deepEqual(report.samples.map(row => row.measured_value), [11, 10, 14, 19]);
  assert.deepEqual(report.channels, ['requested.n', 'measured.n', 'temp.c']);
  assert.deepEqual(report.samples[3].values, [16, 19, 23]);
  assert.match(report.sign_convention, /measured - requested/);
  assert.match(report.unit_declaration, /no conversion or verification/);
});

test('swapping roles reverses every signed error and bias, retaining absolute metrics', () => {
  const a = trackingError(source, options);
  const b = trackingError(source, { ...options, requested: options.measured, measured: options.requested });
  assert.deepEqual(b.samples.map(row => row.error), [-1, 2, 0, -3]);
  assert.equal(b.bias, -a.bias);
  for (const key of ['mae', 'rmse', 'max_abs_error']) assert.equal(b[key], a[key]);
});

test('constant offsets, exact zero and singleton selections are well defined', () => {
  for (const offset of [-4, 0, 4]) {
    const r = trackingError(csv([1, 2, 3], [1, 2, 3].map(value => value + offset)), config);
    assert.equal(r.bias, offset);
    for (const key of ['mae', 'rmse', 'max_abs_error']) assert.equal(r[key], Math.abs(offset));
  }
  const one = trackingError(source, { ...options, window: ['1100', '1100'] });
  assert.equal(one.bias, -2); assert.equal(one.rmse, 2); assert.equal(one.sample_count, 1);
});

test('irregular cadence retains equal row weights and never inserts observations', () => {
  const regular = source.replace('1300', '1200').replace('9000', '1300');
  const a = trackingError(source, options), b = trackingError(regular, options);
  for (const key of ['bias', 'mae', 'rmse', 'max_abs_error', 'sample_count']) assert.equal(a[key], b[key]);
  assert.match(a.weighting, /not elapsed time/);
  assert.deepEqual(a.samples.map(row => row.timestamp_ms), ['1000', '1100', '1300', '9000']);
});

test('inclusive exact Int64 timestamps and physical source lines survive JSON and CSV reopening', () => {
  const input = '\ufefftimestamp_ms,r,m\r\n9007199254740992,1,2\r\n\r\n9007199254740993,2,4\r\n9223372036854775807,3,6';
  const report = trackingError(input, { ...config, window: ['9007199254740993', '9223372036854775807'] });
  assert.deepEqual(report.samples.map(row => row.timestamp_ms), ['9007199254740993', '9223372036854775807']);
  assert.deepEqual(report.samples.map(row => row.source_line), [4, 5]);
  assert.deepEqual(report.samples.map(row => row.sample_index), [1, 2]);
  assert.equal(report.source_sha256, hash(input));
  assert.equal(report.total_source_samples, 3);
  assert.deepEqual(JSON.parse(JSON.stringify(report)), report);
  assert.deepEqual(parseRecording(trackingErrorCsv(report)).rows.map(row => row.timestamp_ms), report.samples.map(row => row.timestamp_ms));
});

test('empty windows expose null metrics and refuse a non-reopenable numeric CSV', () => {
  const r = trackingError(source, { ...options, window: ['2000', '3000'] });
  for (const key of ['bias', 'mae', 'rmse', 'max_abs_error', 'selected_span', 'error_csv_sha256']) assert.equal(r[key], null);
  assert.equal(r.sample_count, 0); assert.deepEqual(r.samples, []);
  assert.throws(() => trackingErrorCsv(r), /empty window/);
});

test('complete source validation includes unselected rows and unrelated columns', () => {
  for (const bad of ['10000,2,3,NaN', '10000,2,,3', '10000,2,3', '9000,1,2,3', '9223372036854775808,1,2,3', '10000,2,"3",4']) {
    assert.throws(() => trackingError(source + bad, { ...options, window: ['1000', '1100'] }));
  }
  assert.throws(() => trackingError('timestamp_ms,r,r\n0,1,2', config), /duplicate/);
  assert.throws(() => trackingError('timestamp_ms,r,m', config), /at least one sample/);
});

test('requires explicit different channel roles, common units and valid windows', () => {
  for (const change of [{ commonUnit: '' }, { commonUnit: undefined }, { commonUnit: 'N\n' }, { requested: 'missing' }, { measured: options.requested }, { window: ['2', '1'] }, { window: [0, 1] }, { window: ['0', '9223372036854775808'] }, { window: ['-1', '3'] }, { window: ['1'] }]) {
    assert.throws(() => trackingError(source, { ...options, ...change }));
  }
  assert.throws(() => trackingError(' '.repeat(4 * 1024 * 1024 + 1), config), /4 MiB/);
});

test('scaled statistics avoid sum and square overflow for huge finite differences', () => {
  for (const magnitude of [1e300, Number.MAX_VALUE, 1e-300, Number.MIN_VALUE]) {
    const r = trackingError(csv([0, 0], [magnitude, magnitude]), config);
    for (const key of ['bias', 'mae', 'rmse', 'max_abs_error']) assert.equal(r[key], magnitude);
    assert.ok([r.bias, r.mae, r.rmse, r.max_abs_error].every(Number.isFinite));
  }
});

test('compensated signed cancellation and subtraction overflow have explicit behavior', () => {
  const r = trackingError(csv([0, 0, 0], [1e16, 1, -1e16]), config);
  near(r.bias, 1 / 3);
  const opposite = trackingError(csv([0, 0], [Number.MAX_VALUE, -Number.MAX_VALUE]), config);
  assert.equal(opposite.bias, 0); assert.equal(opposite.rmse, Number.MAX_VALUE);
  assert.throws(() => trackingError(csv([-1e308], [1e308]), config), /overflows finite binary64/);
  assert.throws(() => trackingError(csv([1e308], [-1e308]), config), /overflows finite binary64/);
});

test('hostile labels remain literal JSON data and never enter the fixed numeric CSV header', () => {
  const input = 'timestamp_ms,=HYPERLINK(<x>),@measured&\n0,1,2\n';
  const r = trackingError(input, { requested: '=HYPERLINK(<x>)', measured: '@measured&', commonUnit: '\"</script>,=unit' });
  assert.equal(JSON.parse(JSON.stringify(r)).requested_channel, '=HYPERLINK(<x>)');
  assert.equal(JSON.parse(JSON.stringify(r)).common_unit, '\"</script>,=unit');
  assert.equal(trackingErrorCsv(r), 'timestamp_ms,tracking_error\n0,1\n');
  assert.deepEqual(parseRecording(trackingErrorCsv(r)).channels, ['tracking_error']);
});

test('error numeric CSV reopens in the existing parser and distribution without source metadata loss claims', () => {
  const report = trackingError(source, options), exported = trackingErrorCsv(report);
  assert.equal(report.error_csv_sha256, hash(exported));
  assert.deepEqual(parseRecording(exported).rows.map(row => row.values), [[1], [-2], [0], [3]]);
  const result = distribution(exported, { channel: 'tracking_error', unit: 'N', edges: [-3, 0, 2, 4] });
  assert.deepEqual(result.bins.map(bin => bin.count), [1, 2, 1]);
  assert.match(report.export_warning, /keep this JSON and the source/);
});

test('actual CLI exports and reopens JSON and CSV, then invokes existing distribution CLI', () => {
  const directory = mkdtempSync(join(tmpdir(), 'robo-tracking-error-'));
  try {
    const input = join(directory, 'capture.csv'); writeFileSync(input, source);
    const before = readFileSync(input);
    const report = run(argumentsFor(input)); assert.equal(report.status, 0, report.stderr); assert.equal(report.stderr, '');
    const jsonPath = join(directory, 'error.json'); writeFileSync(jsonPath, report.stdout);
    const reopened = JSON.parse(readFileSync(jsonPath, 'utf8'));
    assert.equal(reopened.bias, 0.5); assert.equal(reopened.source_sha256, hash(before));
    const output = run([...argumentsFor(input), '--format', 'csv']); assert.equal(output.status, 0, output.stderr);
    const csvPath = join(directory, 'error.csv'); writeFileSync(csvPath, output.stdout);
    assert.equal(hash(readFileSync(csvPath)), reopened.error_csv_sha256);
    assert.equal(parseRecording(readFileSync(csvPath, 'utf8')).rows.length, 4);
    const analysis = spawnSync(process.execPath, ['scripts/telemetry-distribution.mjs', csvPath, '--channel', 'tracking_error', '--unit', 'N', '--edges', '-3,0,2,4'], { encoding: 'utf8' });
    assert.equal(analysis.status, 0, analysis.stderr);
    assert.deepEqual(JSON.parse(analysis.stdout).bins.map(bin => bin.count), [1, 2, 1]);
    const visual = spawnSync(process.execPath, ['scripts/telemetry-distribution.mjs', csvPath, '--channel', 'tracking_error', '--unit', '<N&>', '--edges', '-3,0,2,4', '--format', 'svg'], { encoding: 'utf8' });
    assert.equal(visual.status, 0, visual.stderr); assert.match(visual.stdout, /&lt;N&amp;&gt;/);
    assert.deepEqual(readFileSync(input), before);
    for (const extra of [['--common-unit', 'N'], ['--format', 'svg'], ['--unknown', 'x'], ['--window', '2'], ['--window', '2000', '3000', '--format', 'csv']]) {
      const bad = run([...argumentsFor(input), ...extra]); assert.equal(bad.status, 2); assert.equal(bad.stdout, ''); assert.equal(typeof JSON.parse(bad.stderr).error, 'string');
    }
    assert.equal(run([input, '--requested', 'requested.n', '--measured', 'measured.n']).status, 2);
    writeFileSync(input, Buffer.from([0xff, 0xfe]));
    const invalid = run(argumentsFor(input)); assert.equal(invalid.status, 2); assert.equal(invalid.stdout, '');
    writeFileSync(input, 'timestamp_ms,requested.n,measured.n\n0,-1e308,1e308\n');
    const overflow = run(argumentsFor(input)); assert.equal(overflow.status, 2); assert.equal(overflow.stdout, '');
    assert.match(JSON.parse(overflow.stderr).error, /overflows/);
    assert.equal(run(['--help']).status, 0);
  } finally { rmSync(directory, { recursive: true, force: true }); }
});
