import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { hysteresis, hysteresisCsv } from './telemetry-hysteresis.mjs';
import { parseRecording } from './telemetry-recording.mjs';
const input = new URL('../examples/telemetry/hysteresis-noisy.csv', import.meta.url);
const text = readFileSync(input, 'utf8');
const options = { channel: 'load', unit: 'N', enter: 10, exit: 5, maxGapMs: '1000' };
test('noise between levels stays in one episode; equality triggers transitions', () => {
  const r = hysteresis(text, options);
  assert.deepEqual(r.samples.map(s => s.active), [0,1,1,1,1,0,0,1,0,1,1]);
  assert.deepEqual(r.episodes.map(e => [e.first_timestamp_ms,e.last_timestamp_ms,e.observed_span_ms,e.end_reason,e.boundary_timestamp_ms]),
    [['100','400','300','exit-level','500'],['700','700','0','gap','2000'],['2100','2200','100','recording-end',null]]);
  assert.equal(r.episodes[0].sample_count,4);
  assert.equal(r.episodes[0].min,7);
  assert.equal(r.episodes[0].max,10);
  assert.equal(r.segment_count,2);
});
test('generated state CSV feeds existing numeric recording parser without losing timestamps', () => {
  const r = hysteresis(text,options), parsed = parseRecording(hysteresisCsv(r));
  assert.deepEqual(parsed.channels,['hysteresis_active','hysteresis_segment']);
  assert.equal(parsed.rows.length,11);
  assert.deepEqual(parsed.rows[8].values,[0,1]);
});
test('exact Int64 time and cutoff boundary; starts in dead band inactive', () => {
  const r = hysteresis('timestamp_ms,load\n9007199254740993,7\n9007199254740994,10\n9007199254741994,8\n9007199254742995,11\n',options);
  assert.equal(r.episodes[0].observed_span_ms,'1000');
  assert.equal(r.samples[0].active,0);
  assert.equal(r.samples[2].segment,0);
  assert.equal(r.samples[3].segment,1);
  assert.equal(r.episodes[1].first_timestamp_ms,'9007199254742995');
});
test('no episodes and negative levels are supported', () => {
  assert.equal(hysteresis('timestamp_ms,load\n0,0\n',options).episode_count,0);
  assert.deepEqual(hysteresis('timestamp_ms,load\n0,-1\n1,-3\n2,-4\n',{...options,enter:-2,exit:-4}).samples.map(s=>s.active),[1,1,0]);
});
test('invalid settings and malformed unrelated source cells fail', () => {
  for (const change of [{enter:5},{exit:NaN},{maxGapMs:'0'},{maxGapMs:'1.5'},{channel:'absent'}]) assert.throws(()=>hysteresis(text,{...options,...change}));
  assert.throws(()=>hysteresis('timestamp_ms,load,other\n0,10,nope\n',options));
  assert.throws(()=>hysteresis('timestamp_ms,load\n1,10\n1,10\n',options));
});
test('actual CLI emits reusable CSV and errors without partial stdout', () => {
  const cli = new URL('./telemetry-hysteresis.mjs', import.meta.url);
  const args = [cli.pathname,input.pathname,'--channel','load','--unit','N','--enter','10','--exit','5','--max-gap-ms','1000'];
  const ok = spawnSync(process.execPath,[...args,'--format','csv'],{encoding:'utf8'});
  assert.equal(ok.status,0); assert.equal(ok.stderr,'');
  assert.equal(ok.stdout,hysteresisCsv(hysteresis(text,options)));
  const bad = spawnSync(process.execPath,[...args,'--enter','12'],{encoding:'utf8'});
  assert.equal(bad.status,2); assert.equal(bad.stdout,''); assert.match(JSON.parse(bad.stderr).error,/repeated/);
});
