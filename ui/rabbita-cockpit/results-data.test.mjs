import test from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { inspectResults, failureGroups, filterExperiments } from './results-data.js'

test('exported smoke keeps complete failed motions, signed returns and provenance', async () => {
  const report = inspectResults(JSON.parse(await readFile(new URL('./public/results/smoke.json', import.meta.url), 'utf8')))
  const groups = failureGroups(report.evaluation.per_clip)
  assert.equal(groups.reduce((n, g) => n + g.count, 0), report.evaluation.n_clips)
  assert.equal(groups.reduce((n, g) => n + g.failed, 0), report.evaluation.n_failed)
  assert.equal(report.training_started, false)
  assert.ok(report.sources.every(source => /^[a-f0-9]{64}$/.test(source.sha256)))
  const changed = structuredClone(report)
  changed.evaluation.per_clip[0].normalized_return = -.25
  assert.equal(inspectResults(changed).evaluation.per_clip[0].normalized_return, -.25)
  changed.evaluation.n_failed--
  assert.throws(() => inspectResults(changed), /计数/)
})

test('experiment filters retain zero-candidate evaluations and do not infer qualification', () => {
  const experiments = [
    { experiment_id: 'aligned-smoke', candidates: [] },
    { experiment_id: 'recorded-failure', candidates: [{ producer_qualified: false }] },
    { experiment_id: 'recorded-pass', candidates: [{ producer_qualified: true }] },
  ]
  assert.deepEqual(filterExperiments(experiments, '', 'full', []), [experiments[0]])
  assert.deepEqual(filterExperiments(experiments, 'recorded', 'pass', []), [experiments[2]])
  assert.deepEqual(filterExperiments(experiments, 'failure', 'replay', ['recorded-failure']), [experiments[1]])
  assert.equal(filterExperiments(experiments, '<script>', '', []).length, 0)
})
