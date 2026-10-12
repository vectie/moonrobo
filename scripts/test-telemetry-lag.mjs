import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { scanLag, selectLag, lagCsv, lagSvg } from './telemetry-lag.mjs';
import { parseRecording, distribution } from './telemetry-distribution.mjs';
import { stitch, stitchCsv } from './telemetry-stitch.mjs';

const fixture = readFileSync(new URL('../examples/telemetry/delayed-response.csv', import.meta.url), 'utf8');
const config = { reference: 'command.n', response: 'measured.n', referenceUnit: 'N', responseUnit: 'N', maxLagSamples: 4, minPairs: 6 };
const csv = (x, y, start = 0n, interval = 100n) => 'timestamp_ms,x,y\n' + x.map((v, i) => `${start + BigInt(i) * interval},${v},${y[i]}`).join('\n') + '\n';
const opts = { reference: 'x', response: 'y', referenceUnit: 'u', responseUnit: 'v', maxLagSamples: 2, minPairs: 3 };
const close = (a, b, tolerance = 1e-12) => assert.ok(Math.abs(a - b) <= tolerance, `${a} != ${b}`);
const cli = fileURLToPath(new URL('./telemetry-lag.mjs', import.meta.url));
const cliArgs = ['--reference', 'command.n', '--response', 'measured.n', '--reference-unit', 'N', '--response-unit', 'N', '--max-lag-samples', '4', '--min-pairs', '6'];
const run = args => spawnSync(process.execPath, [cli, ...args], { encoding: 'utf8' });

test('known delayed response selects +2 samples and retains exactly ten real pairs', () => {
  const report = scanLag(fixture, config);
  assert.equal(report.sample_interval_ms, '100');
  assert.deepEqual(report.highest_positive_association.lag_samples, [2]);
  close(report.highest_positive_association.correlation, 1);
  const selected = selectLag(report, 2);
  assert.equal(selected.recorded_offset_ms, '200');
  assert.equal(selected.pair_count, 10);
  assert.equal(selected.pairs.length, 10);
  for (const pair of selected.pairs) {
    assert.equal(pair.response_value, 2 * pair.reference_value + 1);
    assert.equal(BigInt(pair.response_timestamp_ms) - BigInt(pair.reference_timestamp_ms), 200n);
  }
  assert.equal(selected.pairs[0].reference_timestamp_ms, '1000');
  assert.equal(selected.pairs[0].response_timestamp_ms, '1200');
  assert.equal(selected.pairs.at(-1).reference_timestamp_ms, '1900');
  assert.equal(selected.pairs.at(-1).response_timestamp_ms, '2100');
});

test('swapping channel roles reverses lag sign and preserves the observed association', () => {
  const report = scanLag(fixture, { ...config, reference: 'measured.n', response: 'command.n' });
  assert.deepEqual(report.highest_positive_association.lag_samples, [-2]);
  const selected = selectLag(report, -2);
  assert.equal(selected.recorded_offset_ms, '-200');
  assert.equal(selected.pairs[0].reference_timestamp_ms, '1200');
  assert.equal(selected.pairs[0].response_timestamp_ms, '1000');
});

test('hand-computed Pearson uses overlap-specific centering and signed association', () => {
  const report = scanLag(csv([1, 2, 3, 4], [1, 4, 2, 3]), { ...opts, maxLagSamples: 1 });
  // At zero: means 2.5, cross-deviation sum 2, squared deviations 5 each.
  close(report.lags.find(row => row.lag_samples === 0).correlation, 0.4);
  const opposite = scanLag(csv([0, 2, -1, 4], [0, -2, 1, -4]), { ...opts, maxLagSamples: 0 });
  close(opposite.lags[0].correlation, -1);
  assert.equal(opposite.highest_positive_association, null);
});

test('all lags retain varying overlap counts; insufficient pairs remain explicitly undefined', () => {
  const report = scanLag(fixture, { ...config, maxLagSamples: 8 });
  for (const row of report.lags) assert.equal(row.pair_count, 12 - Math.abs(row.lag_samples));
  assert.equal(report.lags[0].status, 'insufficient-pairs');
  assert.equal(report.lags[0].correlation, null);
  assert.equal(report.lags.find(row => row.lag_samples === 6).status, 'calculated');
  assert.throws(() => selectLag(report, 7), /minimum pairs/);
  assert.throws(() => selectLag(report, 9), /outside scanned range/);
});

test('constant channels are undefined rather than a zero or perfect score', () => {
  const varying = [0, 1, -2, 3, 1];
  const flat = varying.map(() => 7);
  for (const [x, y, status] of [[flat, varying, 'reference-constant'], [varying, flat, 'response-constant'], [flat, flat, 'both-constant']]) {
    const report = scanLag(csv(x, y), opts);
    assert.ok(report.lags.every(row => row.status === status && row.correlation === null));
    assert.equal(report.highest_positive_association, null);
    assert.equal(selectLag(report, 0).pairs.length, 5);
  }
});

test('periodic repeated patterns retain numerically tied candidate lags instead of one arbitrary peak', () => {
  const xs = [1, -1, 1, -1, 1, -1, 1, -1];
  const report = scanLag(csv(xs, xs), opts);
  assert.deepEqual(report.highest_positive_association.lag_samples, [-2, 0, 2]);
  close(report.lags[1].correlation, -1);
});

test('exact Int64 window and paired timestamps survive above binary64 integer precision', () => {
  const start = 9223372036854775797n;
  const text = csv([0, 1, 4, 2, -1, 3, 2, 0], [7, 0, 1, 4, 2, -1, 3, 2], start, 1n);
  const report = scanLag(text, { ...opts, window: [(start + 1n).toString(), (start + 6n).toString()] });
  assert.equal(report.sample_count, 6);
  assert.equal(report.samples[0].sample_index, 1);
  assert.equal(report.samples[0].source_line, 3);
  const selection = selectLag(report, 1);
  assert.equal(selection.recorded_offset_ms, '1');
  assert.equal(selection.pairs[0].reference_timestamp_ms, (start + 1n).toString());
  assert.equal(selection.pairs[0].response_timestamp_ms, (start + 2n).toString());
  const reopened = parseRecording(lagCsv(report, 1));
  assert.equal(reopened.rows.at(-1).timestamp_ms, (start + 5n).toString());
});

test('irregular gaps are refused within selection but an uninterrupted explicit window is usable', () => {
  const text = 'timestamp_ms,x,y\n0,1,2\n100,2,4\n200,3,6\n1000,4,8\n';
  assert.throws(() => scanLag(text, opts), /exact regular interval/);
  const report = scanLag(text, { ...opts, maxLagSamples: 0, window: ['0', '200'] });
  assert.equal(report.sample_count, 3);
  assert.equal(report.total_source_samples, 4);
  close(report.lags[0].correlation, 1);
});

test('source digest, physical blank-line lineage, and unrelated source values are retained', () => {
  const text = '\n' + fixture.replace('1100,', '\n1100,').replaceAll('\n', '\r\n');
  const report = scanLag(text, config);
  assert.equal(report.source_sha256, createHash('sha256').update(text).digest('hex'));
  const selected = selectLag(report, 2);
  assert.equal(selected.pairs[0].reference_source_line, 3);
  assert.equal(selected.pairs[0].response_source_line, 6);
  assert.deepEqual(report.channels, ['command.n', 'measured.n', 'temp.c']);
  assert.deepEqual(report.samples[2].values, [-1, 1, 21]);
  assert.throws(() => scanLag(fixture + '2200,1,2,bad\n', { ...config, window: ['1000', '1900'] }), /finite decimal/);
});

test('large and tiny finite channel scales do not overflow covariance', () => {
  for (const scale of [1e300, 1e-300]) {
    const report = scanLag(csv([1, 2, -1, 3, 0].map(x => x * scale), [2, 4, -2, 6, 0].map(x => x * scale)), { ...opts, maxLagSamples: 0 });
    assert.equal(report.lags[0].status, 'calculated'); close(report.lags[0].correlation, 1);
  }
});

test('ordinary invalid selections fail before producing misleading correlation', () => {
  for (const change of [{ reference: 'missing' }, { response: 'command.n' }, { referenceUnit: '' }, { maxLagSamples: 257 }, { maxLagSamples: 12 }, { minPairs: 2 }, { minPairs: 13 }, { window: ['2100', '1000'] }, { window: ['-1', '1500'] }, { window: ['1000', '1100'] }]) {
    assert.throws(() => scanLag(fixture, { ...config, ...change }));
  }
  assert.throws(() => scanLag(csv(Array(8193).fill(1), Array(8193).fill(2)), opts), /3 to 8192/);
});

test('SVG escapes channel text and exposes null lags without connecting across them', () => {
  const report = scanLag(fixture, { ...config, maxLagSamples: 8 });
  report.reference_channel = '<command & "x">';
  const svg = lagSvg(report);
  assert.ok(svg.includes('&lt;command &amp; &quot;x&quot;&gt;'));
  assert.ok(!svg.includes('<command'));
  assert.ok(svg.includes('insufficient-pairs; 4 pairs'));
  assert.ok(svg.includes('positive = later response'));
  assert.ok(!/NaN|Infinity/.test(svg));
  const flat = scanLag(csv([1, 1, 1], [2, 2, 2]), { ...opts, maxLagSamples: 0 });
  assert.ok(lagSvg(flat).includes('both-constant'));
});

test('rotated capture reconstruction continues into lag selection and existing distribution analysis', () => {
  const lines = fixture.trim().split('\n');
  const text = stitchCsv(stitch([{ name: 'part-1.csv', text: lines.slice(0, 8).join('\n') }, { name: 'part-2.csv', text: [lines[0], ...lines.slice(6)].join('\n') }], { clock: 'same-recorded-clock', overlap: 'require-equal', maxGapMs: '100' }));
  const report = scanLag(text, config);
  assert.deepEqual(report.highest_positive_association.lag_samples, [2]);
  const paired = lagCsv(report, 2);
  const result = distribution(paired, { channel: 'lagged-response:measured.n', unit: 'N', edges: [-5, 0, 5, 11] });
  assert.equal(result.sample_count, 10);
  assert.deepEqual(result.bins.map(bin => bin.count), [3, 2, 5]);
});

test('actual CLI writes/reopens JSON, SVG, paired CSV and invokes distribution without changing source', () => {
  const directory = mkdtempSync(join(tmpdir(), 'moonrobo-lag-'));
  try {
    const input = join(directory, 'capture.csv'); writeFileSync(input, fixture);
    const original = readFileSync(input);
    const scan = run([input, ...cliArgs]); assert.equal(scan.status, 0, scan.stderr);
    writeFileSync(join(directory, 'scan.json'), scan.stdout);
    assert.deepEqual(JSON.parse(readFileSync(join(directory, 'scan.json'), 'utf8')).highest_positive_association.lag_samples, [2]);
    const selected = run([input, ...cliArgs, '--lag-samples', '2']); assert.equal(selected.status, 0, selected.stderr);
    writeFileSync(join(directory, 'selection.json'), selected.stdout);
    assert.equal(JSON.parse(selected.stdout).selection.pairs.length, 10);
    const plot = run([input, ...cliArgs, '--format', 'svg']); assert.equal(plot.status, 0, plot.stderr);
    writeFileSync(join(directory, 'scan.svg'), plot.stdout); assert.match(readFileSync(join(directory, 'scan.svg'), 'utf8'), /<svg/);
    const paired = run([input, ...cliArgs, '--lag-samples', '2', '--format', 'csv']); assert.equal(paired.status, 0, paired.stderr);
    const pairFile = join(directory, 'pairs.csv'); writeFileSync(pairFile, paired.stdout);
    assert.equal(parseRecording(readFileSync(pairFile, 'utf8')).rows.length, 10);
    const distributionCli = fileURLToPath(new URL('./telemetry-distribution.mjs', import.meta.url));
    const child = spawnSync(process.execPath, [distributionCli, pairFile, '--channel', 'lagged-response:measured.n', '--unit', 'N', '--edges', '-5,0,5,11'], { encoding: 'utf8' });
    assert.equal(child.status, 0, child.stderr);
    assert.deepEqual(JSON.parse(child.stdout).bins.map(bin => bin.count), [3, 2, 5]);
    assert.deepEqual(readFileSync(input), original);
    for (const extra of [['--format', 'csv'], ['--lag-samples', '9'], ['--min-pairs', '3'], ['--format', 'svg', '--lag-samples', '2']]) {
      const invalid = run([input, ...cliArgs, ...extra]); assert.equal(invalid.status, 2); assert.equal(invalid.stdout, ''); assert.equal(typeof JSON.parse(invalid.stderr).error, 'string');
    }
    writeFileSync(input, Buffer.from([0xff, 0xfe]));
    const invalidUtf8 = run([input, ...cliArgs]); assert.equal(invalidUtf8.status, 2); assert.equal(invalidUtf8.stdout, '');
    assert.equal(run(['--help']).status, 0);
  } finally { rmSync(directory, { recursive: true, force: true }); }
});
