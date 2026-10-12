import test from 'node:test'
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { inspectRetainedTrial, compareRetainedTrials } from './digital-trial-catalogue.js'
import { createTrialComparisonDossier, verifyTrialComparisonDossier, downloadComparisonDossier, DOSSIER_LIMIT } from './trial-comparison-dossier.js'

const digest = 'sha256:' + 'a'.repeat(64)
function source(id, value = 0) {
  const payload = { physical_execution_allowed: false, automatic_retry_allowed: false,
    binding_state: 'blocked', acknowledgement_state: 'unknown', retention_state: 'pending-book-review',
    current_binding_blockers: ['Historical file differs'], current_binding_unknowns: ['Calibration unknown'],
    record: { contract_id: 'moonrobo.digital-trial.v1', revision: 1,
      import_request: { trial_id: id, dossier_text: '\ufeffexact\r\n世界\u0000<script>bad()</script>', result_text: ' result\r\n ' },
      events: [{ kind: 'lost-ack', event_id: 'lost', reviewer: '', note: 'lost\u0000\n<img src=x onerror=evil()>', proof_text: '', now_ms: '17' }],
      binding: { trial_id: id, digital_result: 'accepted', result_digest: digest, baseline_digest: digest,
        blockers: [], limitations: ['Digital only'], frozen_evidence: {
          contract_id: 'moonrobo.frozen-digital-evidence.v1', physical_execution_allowed: false,
          baseline_verified: true, baseline_digest: digest,
          scenario_id: 'a\n# hostile\n<script>x()</script>',
          metrics: [{ key: 'distance_m', unit: 'm', value, available: true }],
        } },
    },
  }
  return { ...inspectRetainedTrial(payload, id), observedAt: 1700000000000, host: 'same-origin host' }
}
const sha = (text) => 'sha256:' + createHash('sha256').update(text, 'utf8').digest('hex')

test('R50 exact payload strings and ordered events survive JSON UTF-8 export and inert reopen', async () => {
  const a = source('a'), b = source('b', 20)
  b.binding.digital_result = 'rejected'
  b.observedAt += 50
  const files = await createTrialComparisonDossier(a, b, 1700000000100)
  const verified = await verifyTrialComparisonDossier(files.json, files.markdown)
  assert.equal(verified.markdown, files.markdown)
  const e = verified.envelope
  for (const [index, original] of [a, b].entries()) {
    const observation = e.observations[index]
    assert.equal(observation.payload_digest, sha(observation.payload_json))
    assert.deepEqual(JSON.parse(observation.payload_json), original.payload)
    assert.equal(JSON.parse(observation.payload_json).record.import_request.dossier_text, original.record.import_request.dossier_text)
  }
  assert.equal(e.manifest.readable_markdown_sha256, sha(files.markdown))
  assert.equal(e.export_id, sha(JSON.stringify([e.contract_id, e.exported_at_ms,
    e.observations.map((item) => [item.side, item.trial_id, item.observed_at_ms, item.host, item.payload_digest])])))
  assert.deepEqual(e.comparison, compareRetainedTrials(a, b))
  assert.equal(e.comparison.rows[0].a, 0); assert.equal(e.comparison.rows[0].delta, 20)
  assert.equal(e.comparison.rows[1].delta, null)
  assert.match(files.markdown, /Historical host observation/)
  assert.match(files.markdown, /No atomic cross-trial snapshot/)
  assert.match(files.markdown, /not authorship or trust/)
  assert.match(files.markdown, new RegExp(e.export_id))
  assert.match(verified.message, /Self-consistency only/)
  await assert.rejects(verifyTrialComparisonDossier(files.json, files.markdown + '\n'), /Companion Markdown/)
  const other = await createTrialComparisonDossier(a, b, 1700000000200)
  await assert.rejects(verifyTrialComparisonDossier(files.json, other.markdown), /Companion Markdown/)
  assert.doesNotMatch(files.markdown, /<script>|<img|\n# hostile/)
  assert.match(files.markdown, /&#60;script/)
  assert.equal(e.observations[1].observed_at_ms - e.observations[0].observed_at_ms, 50)
})

test('R50 same trial twice, different and unverified baselines keep shared numeric semantics', async () => {
  const a = source('a'), b = source('b')
  const same = await createTrialComparisonDossier(a, a, 1)
  assert.equal(same.envelope.comparison.rows[0].delta, 0)
  for (const verified of [true, false]) {
    b.binding.baseline_digest = 'sha256:' + 'b'.repeat(64)
    b.evidence.baseline_digest = b.binding.baseline_digest
    b.evidence.baseline_verified = verified
    b.verifiedBaseline = verified
    const result = await createTrialComparisonDossier(a, b, 1)
    assert.equal(result.envelope.comparison.state, 'different-or-unverified-baseline')
    assert.ok(result.envelope.comparison.rows.every((row) => row.delta === null))
    await verifyTrialComparisonDossier(result.json)
  }
})

test('R50 verification rejects digest tampering, changed summaries, authority, versions, selection and oversize', async () => {
  const files = await createTrialComparisonDossier(source('a'), source('b'), 1)
  for (const mutate of [
    (e) => { e.observations[0].payload_json += ' ' },
    (e) => { e.observations[0].payload_digest = 'sha256:' + '0'.repeat(64) },
    (e) => { e.observations[1].side = 'A' },
    (e) => { e.observations[0].trial_id = 'wrong' },
    (e) => { e.comparison.rows[0].delta = 99 },
    (e) => { e.readable_markdown += '\nAltered' },
    (e) => { e.manifest.readable_markdown_sha256 = digest },
    (e) => { e.physical_execution_allowed = true },
    (e) => { e.contract_id = 'moonrobo.trial-comparison-dossier.v2' },
    (e) => { e.observations[0].observed_at_ms = -1 },
    (e) => { e.export_id = digest },
  ]) {
    const changed = JSON.parse(files.json); mutate(changed)
    await assert.rejects(verifyTrialComparisonDossier(JSON.stringify(changed)))
  }
  await assert.rejects(verifyTrialComparisonDossier('x'.repeat(DOSSIER_LIMIT + 1)), /size limit/)
  await assert.rejects(createTrialComparisonDossier(source('a'), null, 1), /both trials/)
  const missing = source('b'); delete missing.record.import_request.result_text
  await assert.rejects(createTrialComparisonDossier(source('a'), missing, 1), /original dossier and result/)
})

test('R50 snapshot is captured before asynchronous digest; downloads preserve exact files and MIME', async () => {
  const a = source('a'), b = source('b')
  const original = JSON.stringify(a.payload)
  const pending = createTrialComparisonDossier(a, b, 1)
  a.record.import_request.dossier_text = 'changed after export click'
  const files = await pending
  assert.equal(files.envelope.observations[0].payload_json, original)
  const blobs = [], clicks = [], revoked = []
  const document = { body: { appendChild() {} }, createElement: () => ({ click() { clicks.push(this.download) }, remove() {} }) }
  const url = { createObjectURL(blob) { blobs.push(blob); return `blob:${blobs.length}` }, revokeObjectURL(href) { revoked.push(href) } }
  downloadComparisonDossier(files, document, url)
  const stem = 'trial-comparison-' + files.envelope.export_id.slice(7, 23)
  assert.deepEqual(clicks, [`${stem}.md`, `${stem}.json`])
  assert.deepEqual(revoked, ['blob:1', 'blob:2'])
  assert.equal(await blobs[0].text(), files.markdown)
  assert.equal(await blobs[1].text(), files.json)
  assert.equal(blobs[1].type, 'application/json')
})
