import test from 'node:test'
import assert from 'node:assert/strict'
import { readFile, writeFile, mkdir, readdir, mkdtemp } from 'node:fs/promises'
import { createHash } from 'node:crypto'
import { spawn, spawnSync } from 'node:child_process'
import { tmpdir } from 'node:os'
import path from 'node:path'
import net from 'node:net'
import { mountDigitalTrials } from './digital-trials.js'
import { inspectRetainedTrial, compareRetainedTrials } from './digital-trial-catalogue.js'
import { createTrialComparisonDossier, verifyTrialComparisonDossier } from './trial-comparison-dossier.js'

class Element {
  constructor() { this.listeners = new Map(); this.value = ''; this.textContent = ''; this.dataset = {}; this.disabled = false; this.files = []; this.children = [] }
  get value() { return this._value }
  set value(value) { this._value = value; if (value === '' && this.files) this.files = [] }
  addEventListener(name, fn) { this.listeners.set(name, [...(this.listeners.get(name) || []), fn]) }
  async dispatch(name) { for (const fn of this.listeners.get(name) || []) await fn({ target: this }) }
  replaceChildren(...children) { this.children = children; this.value = children[0]?.value || '' }
  setAttribute() {}
  showModal() { this.open = true }
  close() { this.open = false; return this.dispatch('close') }
}
class Root extends Element {
  constructor() { super(); this.ownerDocument = { createElement: () => new Element() } }
  set innerHTML(markup) { this.markup = markup; this.elements = new Map([...markup.matchAll(/id="([^"]+)"/g)].map(([, id]) => [id, new Element()])) }
  querySelector(selector) { const el = this.elements.get(selector.slice(1)); assert.ok(el, selector); return el }
}
function harness(fetchImpl, hostUrl = '', options = {}) {
  const root = new Root(), dialog = new Element(), requests = [], downloads = []
  const api = mountDigitalTrials({ root, dialog, launcher: new Element(), hostUrl,
    fetchImpl: async (url, options) => { requests.push({ url, ...options }); return fetchImpl(url, options) },
    downloadDossier: (files) => downloads.push(files), ...options,
  })
  const el = (id) => root.querySelector(`#rt-${id}`)
  return { root, dialog, requests, downloads, api, el,
    refresh: () => el('refresh').dispatch('click'),
    select: (side, value) => { el(side).value = value; return el(side).dispatch('change') },
  }
}
const hash = (bytes) => createHash('sha256').update(bytes).digest('hex')
const digest = 'sha256:' + 'a'.repeat(64)
function payload(id, decision = 'accepted') {
  return { physical_execution_allowed: false, automatic_retry_allowed: false,
    state: 'unknown', binding_state: 'unknown', acknowledgement_state: 'confirmed', retention_state: 'pending-book-review', blockers: [], unknowns: ['Calibration unqualified'],
    record: { contract_id: 'moonrobo.digital-trial.v1', revision: 0, events: [], import_request: { trial_id: id, dossier_text: 'exact dossier\r\n', result_text: 'exact result\u0000' }, binding: {
      trial_id: id, digital_result: decision, result_digest: digest, baseline_digest: digest,
      robot_id: 'rover', robot_revision: 'r1', blockers: decision === 'rejected' ? ['Digital result rejected'] : [], limitations: ['Digital only'],
      frozen_evidence: { contract_id: 'moonrobo.frozen-digital-evidence.v1', physical_execution_allowed: false,
        baseline_verified: true, baseline_digest: digest,
        metrics: [{ key: 'distance_m', value: 60, unit: 'm', available: true }],
      },
    } },
  }
}
const catalogue = (entries = ['a', 'b'].map((trial_id) => ({ trial_id, state: 'verified', selectable: true }))) => ({ contract_id: 'moonrobo.digital-trial-catalogue.v1', physical_execution_allowed: false, state: 'available', limit: 32, truncated: false, entries })
const response = (data, status = 200) => ({ ok: status === 200, status, json: async () => data, text: async () => JSON.stringify(data) })
const queue = (...items) => async () => { const item = items.shift(); if (typeof item === 'function') return item(); if (item instanceof Error) throw item; assert.ok(item); return item }

test('R37 matching verified baseline permits descriptive numeric deltas only', () => {
  const a = payload('a'), b = payload('b', 'rejected')
  b.record.binding.frozen_evidence.metrics[0].value = 70
  let view = compareRetainedTrials(inspectRetainedTrial(a, 'a'), inspectRetainedTrial(b, 'b'))
  assert.equal(view.rows[0].delta, 10); assert.equal(view.rows[1].delta, null)
  assert.match(view.message, /No ranking or readiness/)
  b.record.binding.baseline_digest = 'sha256:' + 'b'.repeat(64)
  b.record.binding.frozen_evidence.baseline_digest = b.record.binding.baseline_digest
  view = compareRetainedTrials(inspectRetainedTrial(a, 'a'), inspectRetainedTrial(b, 'b'))
  assert.equal(view.state, 'different-or-unverified-baseline'); assert.ok(view.rows.every((row) => row.delta === null))
  b.record.binding.baseline_digest = digest
  b.record.binding.frozen_evidence.baseline_digest = digest
  b.record.binding.frozen_evidence.baseline_verified = false
  assert.equal(compareRetainedTrials(inspectRetainedTrial(a, 'a'), inspectRetainedTrial(b, 'b')).rows[0].delta, null)
})

test('R37 missing nonfinite wrong-unit string duplicate and unsupported metrics are unavailable', () => {
  for (const value of [null, undefined, NaN, Infinity, -Infinity, '4']) {
    const a = payload('a'); a.record.binding.frozen_evidence.metrics[0].value = value
    assert.equal(compareRetainedTrials(inspectRetainedTrial(a, 'a'), inspectRetainedTrial(a, 'a')).rows[0].delta, null)
  }
  const a = payload('a'); a.record.binding.frozen_evidence.metrics[0].unit = 'km'
  assert.equal(compareRetainedTrials(inspectRetainedTrial(a, 'a'), inspectRetainedTrial(a, 'a')).rows[0].a, null)
  a.record.binding.frozen_evidence.metrics = [{ key: 'science_score', value: 99, unit: 'score', available: true }]
  assert.ok(compareRetainedTrials(inspectRetainedTrial(a, 'a'), inspectRetainedTrial(a, 'a')).rows.every((row) => row.a === null))
  a.record.binding.frozen_evidence.metrics = [payload('a').record.binding.frozen_evidence.metrics[0], payload('a').record.binding.frozen_evidence.metrics[0]]
  assert.equal(compareRetainedTrials(inspectRetainedTrial(a, 'a'), inspectRetainedTrial(a, 'a')).rows[0].a, null)
})

test('R37 actual panel keeps frozen outcome, current binding, acknowledgement, reviews and raw history distinct', async () => {
  const a = payload('a'), b = payload('b', 'rejected')
  a.binding_state = 'blocked'; a.current_binding_blockers = ['Current profile differs']; a.acknowledgement_state = 'unknown'
  a.record.revision = 2; a.record.events = [{ kind: 'lost-ack', event_id: 'lost', note: 'Unknown receipt', now_ms: '1' }, { kind: 'review', event_id: 'review', reviewer: '<img src=x onerror=alert(1)>', note: '<script>hostile()</script>', now_ms: '2' }]
  const h = harness(queue(response(catalogue()), response(a), response(b)))
  await h.refresh(); await h.select('left', 'a'); await h.select('right', 'b')
  assert.match(h.el('left-outcome').textContent, /Decision: accepted/)
  assert.match(h.el('left-binding').textContent, /Current profile differs/)
  assert.match(h.el('left-history').textContent, /Import acknowledgement: unknown/)
  assert.match(h.el('left-history').textContent, /Named reviews \(1\)/)
  assert.match(h.el('left-history').textContent, /<script>hostile\(\)<\/script>/)
  assert.equal(h.el('left-raw').textContent, JSON.stringify(a, null, 2))
  assert.match(h.el('right-outcome').textContent, /Decision: rejected/)
  assert.ok(h.requests.every((item) => item.method === 'GET' && !item.body))
  assert.doesNotMatch(h.root.markup, /hostile\(\)/)
})

test('R37 rapid selection, failed second side, refresh and close suppress stale evidence', async () => {
  let release
  const h = harness(queue(response(catalogue()), () => new Promise((resolve) => { release = resolve }), response(payload('b')), response({}, 409)))
  await h.refresh()
  const old = h.select('left', 'a'); await Promise.resolve()
  await h.select('left', 'b'); release(response(payload('a'))); await old
  assert.match(h.el('left-status').textContent, /Inspected b/)
  await h.select('right', 'a')
  assert.match(h.el('right-status').textContent, /Unavailable/)
  assert.equal(h.el('right-raw').textContent, 'Unavailable')
  assert.equal(h.el('comparison').textContent, 'Unavailable')
  let late
  const closed = harness(queue(response(catalogue()), () => new Promise((resolve) => { late = resolve })))
  await closed.refresh(); const pending = closed.select('left', 'a'); await Promise.resolve()
  await closed.dialog.close(); late(response(payload('a'))); await pending
  assert.equal(closed.el('left-raw').textContent, 'Unavailable')
  let refreshLate
  const newer = harness(queue(() => new Promise((resolve) => { refreshLate = resolve }), response({ ...catalogue([]), state: 'empty' })))
  const initial = newer.refresh(); await Promise.resolve(); await newer.refresh()
  refreshLate(response(catalogue())); await initial
  assert.match(newer.el('status').textContent, /Catalogue: empty/)
})

test('R37 missing invalid truncated catalogue and count overflow fail closed', async () => {
  const entries = ['missing-evidence', 'invalid-evidence', 'truncated-history', 'invalid-name'].map((state, index) => ({ trial_id: `bad-${index}`, state, selectable: false, message: '<b>preserve</b>' }))
  const h = harness(queue(response({ ...catalogue([]), state: 'missing' }), response({ ...catalogue(entries), state: 'truncated', truncated: true }), response(catalogue(Array.from({ length: 33 }, (_, index) => ({ trial_id: `trial-${index}`, state: 'verified', selectable: true }))))))
  await h.refresh(); assert.match(h.el('status').textContent, /missing/)
  await h.refresh(); assert.match(h.el('status').textContent, /Truncated/); assert.match(h.el('issues').textContent, /invalid-evidence/)
  assert.equal(h.el('left').children.length, 1)
  await h.refresh(); assert.match(h.el('status').textContent, /over-limit/); assert.equal(h.el('left').disabled, true)
  assert.throws(() => inspectRetainedTrial(payload('a'), 'b'), /invalid/)
})

test('R50 controller exports only inspected evidence and suppresses loading error refresh close and stale exports', async () => {
  let release
  const h = harness(queue(response(catalogue()), response(payload('a')), response(payload('b')), () => new Promise((resolve) => { release = resolve }), response({}, 409), response(catalogue())))
  assert.equal(h.el('dossier-export').disabled, true)
  await h.refresh(); await h.select('left', 'a'); await h.select('right', 'b')
  assert.equal(h.el('dossier-export').disabled, false)
  const requests = h.requests.length
  await h.el('dossier-export').dispatch('click')
  assert.equal(h.downloads.length, 1); assert.equal(h.requests.length, requests)
  const verified = await verifyTrialComparisonDossier(h.downloads[0].json)
  assert.equal(verified.envelope.observations[0].payload_json, JSON.stringify(payload('a')))
  const file = new TextEncoder().encode(h.downloads[0].json)
  h.el('dossier-file').files = [{ size: file.length, arrayBuffer: async () => file.buffer }]
  await h.el('dossier-file').dispatch('change')
  assert.match(h.el('dossier-file-status').textContent, /integrity verified/)
  assert.equal(h.requests.length, requests)
  const corrupt = JSON.parse(h.downloads[0].json)
  corrupt.observations[0].payload_json += ' '
  const corruptBytes = new TextEncoder().encode(JSON.stringify(corrupt))
  h.el('dossier-file').files = [{ size: corruptBytes.length, arrayBuffer: async () => corruptBytes.buffer }]
  await h.el('dossier-file').dispatch('change')
  assert.match(h.el('dossier-file-status').textContent, /rejected: Payload digest mismatch/)
  assert.equal(h.el('dossier-preview').textContent, '')
  assert.equal(h.requests.length, requests)
  const loading = h.select('right', 'a'); await Promise.resolve()
  assert.equal(h.el('dossier-export').disabled, true)
  await h.el('dossier-export').dispatch('click'); assert.equal(h.downloads.length, 1)
  release(response(payload('a'))); await loading
  const pendingExport = h.el('dossier-export').dispatch('click')
  await h.dialog.close(); await pendingExport
  assert.equal(h.downloads.length, 1)
  assert.equal(h.el('dossier-export').disabled, true)
  await h.select('right', 'b'); assert.equal(h.el('dossier-export').disabled, true)
  await h.refresh(); assert.equal(h.el('dossier-export').disabled, true)
})

test('R50 controller preserves exact native response JSON lexemes including signed zero and whitespace', async () => {
  const raw = '\r\n ' + JSON.stringify(payload('a')).replace('"value":60', '"value":-0') + '\n'
  let reads = 0
  const exact = () => ({ ok: true, status: 200, text: async () => { reads++; return raw }, json: async () => JSON.parse(raw) })
  const h = harness(queue(response(catalogue()), exact(), exact()))
  await h.refresh(); await h.select('left', 'a'); await h.select('right', 'a')
  await h.el('dossier-export').dispatch('click')
  assert.equal(h.downloads.length, 1)
  for (const item of h.downloads[0].envelope.observations) {
    assert.equal(item.payload_json, raw)
    assert.equal(item.payload_digest, 'sha256:' + hash(raw))
    assert.ok(Object.is(JSON.parse(item.payload_json).record.binding.frozen_evidence.metrics[0].value, -0))
  }
  assert.equal(reads, 2); assert.equal(h.requests.length, 3)
  await verifyTrialComparisonDossier(h.downloads[0].json)
})

test('R50 file reads and WebCrypto verification cannot publish after close or refresh', async () => {
  const a = { ...inspectRetainedTrial(payload('a'), 'a'), observedAt: 1, host: 'local' }
  const files = await createTrialComparisonDossier(a, a, 2)
  const bytes = new TextEncoder().encode(files.json)
  const markdown = new TextEncoder().encode(files.markdown)
  const h = harness(queue(response(catalogue())))
  let releaseRead
  h.el('dossier-file').files = [{ size: bytes.length, arrayBuffer: () => new Promise((resolve) => { releaseRead = resolve }) }]
  h.el('dossier-file').value = 'C:\\fakepath\\comparison.json'
  h.el('dossier-markdown-file').value = 'C:\\fakepath\\comparison.md'
  h.el('dossier-markdown-file').files = [{ size: markdown.length, arrayBuffer: async () => markdown.buffer }]
  const reading = h.el('dossier-file').dispatch('change')
  await h.refresh(); releaseRead(bytes.buffer); await reading
  assert.equal(h.el('dossier-preview').textContent, '')
  assert.doesNotMatch(h.el('dossier-file-status').textContent, /integrity verified/)
  assert.equal(h.el('dossier-file').value, '')
  assert.equal(h.el('dossier-markdown-file').value, '')
  assert.deepEqual(h.el('dossier-file').files, [])
  assert.deepEqual(h.el('dossier-markdown-file').files, [])
  h.el('dossier-file').files = [{ size: bytes.length, arrayBuffer: async () => bytes.buffer }]
  h.el('dossier-file').value = 'C:\\fakepath\\comparison.json'
  const originalDigest = globalThis.crypto.subtle.digest
  let releaseDigest, notifyDigest
  const started = new Promise((resolve) => { notifyDigest = resolve })
  const gate = new Promise((resolve) => { releaseDigest = resolve })
  globalThis.crypto.subtle.digest = async function (...args) { notifyDigest(); await gate; return originalDigest.apply(this, args) }
  try {
    const verifying = h.el('dossier-file').dispatch('change')
    await started; await h.dialog.close(); releaseDigest(); await verifying
    assert.equal(h.el('dossier-preview').textContent, '')
    assert.doesNotMatch(h.el('dossier-file-status').textContent, /integrity verified/)
    assert.equal(h.el('dossier-file').value, '')
    assert.deepEqual(h.el('dossier-file').files, [])
  } finally { globalThis.crypto.subtle.digest = originalDigest; releaseDigest() }
  // Choosing exactly the same file again can now trigger change in a browser.
  h.el('dossier-file').files = [{ size: bytes.length, arrayBuffer: async () => bytes.buffer }]
  h.el('dossier-file').value = 'C:\\fakepath\\comparison.json'
  await h.el('dossier-file').dispatch('change')
  assert.match(h.el('dossier-file-status').textContent, /integrity verified/)
  assert.equal(h.requests.length, 1)
})

async function filesSnapshot(root) {
  const result = {}
  async function visit(relative) {
    for (const entry of await readdir(path.join(root, relative), { withFileTypes: true })) {
      const name = path.join(relative, entry.name)
      if (entry.isDirectory()) await visit(name)
      else result[name] = hash(await readFile(path.join(root, name)))
    }
  }
  await visit(''); return result
}

test('R37 native HTTP serves the production cockpit and drives its actual read-only controller with preserved store bytes', { skip: !process.env.MOONROBO_NATIVE_HOST }, async () => {
  const host = process.env.MOONROBO_NATIVE_HOST, cli = process.env.MOONROBO_NATIVE_TRIAL, dist = process.env.MOONROBO_BUILD_DIST
  assert.ok(cli && dist)
  const journey = process.env.MOONROBO_TRIAL_JOURNEY_DIR || path.join(tmpdir(), 'moonrobo-r37-http')
  await mkdir(journey, { recursive: true })
  const root = await mkdtemp(path.join(journey, 'run-'))
  const envelopeText = await readFile(new URL('../../fixtures/moonmoon-study.json', import.meta.url), 'utf8')
  const dossier = JSON.parse(JSON.parse(envelopeText).dossier_json)
  for (const source of dossier.sources.filter((source) => source.artifact_ref.startsWith('books/test-rover/'))) {
    const relative = source.artifact_ref.slice('books/test-rover/'.length)
    await mkdir(path.dirname(path.join(root, relative)), { recursive: true })
    await writeFile(path.join(root, relative), source.text)
  }
  const run = (args) => { const result = spawnSync(cli, args, { encoding: 'utf8' }); assert.equal(result.status, 0, result.stderr + result.stdout); return JSON.parse(result.stdout) }
  for (const [id, session] of [['a', 'q11-a'], ['b', 'q11-b']]) {
    const resultText = dossier.sources.find((source) => source.artifact_ref.endsWith(`/${session}/mission-result.json`)).text
    const requestPath = path.join(root, `${id}-request.json`)
    await writeFile(requestPath, JSON.stringify({ trial_id: id, session_id: session, dossier_text: envelopeText, result_text: resultText }))
    run(['import', root, requestPath])
  }
  const different = structuredClone(dossier)
  different.site.revision = 'different-site-baseline'
  for (const alternative of different.alternatives) {
    const baseline = JSON.parse(alternative.baseline_json)
    baseline.site = different.site
    alternative.baseline_json = JSON.stringify(baseline)
    alternative.baseline_digest = 'sha256:' + hash(alternative.baseline_json)
  }
  const differentText = JSON.stringify(different)
  const differentRequest = path.join(root, 'c-request.json')
  await writeFile(differentRequest, JSON.stringify({ trial_id: 'c', session_id: 'q11-a', dossier_text: JSON.stringify({ contract_id: 'moonmoon.mission-study-envelope.v1', dossier_json: differentText, dossier_digest: 'sha256:' + hash(differentText) }), result_text: dossier.sources.find((source) => source.artifact_ref.endsWith('/q11-a/mission-result.json')).text }))
  run(['import', root, differentRequest])
  const eventPath = path.join(root, 'event-request.json')
  await writeFile(eventPath, JSON.stringify({ trial_id: 'a', expected_revision: 0, event_id: 'lost-ack', kind: 'lost-ack', proof_text: '', reviewer: '', note: 'Lost inert acknowledgement', now_ms: '1' }))
  run(['event', root, eventPath])
  await writeFile(eventPath, JSON.stringify({ trial_id: 'a', expected_revision: 1, event_id: 'named-review', kind: 'review', proof_text: '', reviewer: 'Fixture reviewer', note: '<script>retained hostile text</script>', now_ms: '2' }))
  run(['event', root, eventPath])
  const initial = await filesSnapshot(root)
  const socket = net.createServer(); await new Promise((resolve) => socket.listen(0, '127.0.0.1', resolve)); const port = socket.address().port; await new Promise((resolve) => socket.close(resolve))
  const child = spawn(host, ['serve', root, dist, '127.0.0.1', String(port)], { stdio: ['ignore', 'pipe', 'pipe'] })
  let output = ''; child.stdout.on('data', (data) => { output += data }); child.stderr.on('data', (data) => { output += data })
  const origin = `http://127.0.0.1:${port}`
  try {
    let ready = false
    for (let i = 0; i < 100; i++) { try { const result = await fetch(origin + API); if (result.ok) { ready = true; break } } catch {} await new Promise((resolve) => setTimeout(resolve, 50)) }
    assert.ok(ready, output)
    const html = await (await fetch(origin)).text()
    const entry = html.match(/<script[^>]+src="([^"]+)"/)[1]
    const asset = await (await fetch(new URL(entry, origin))).text()
    assert.match(asset, /Retained digital trial catalogue/)
    assert.match(asset, /Matching verified baseline/)
    assert.match(asset, /moonrobo.trial-comparison-dossier.v1/)
    const nativeBodies = new Map()
    const h = harness(async (url, options) => {
      const response = await fetch(url, options)
      nativeBodies.set(url, await response.clone().text())
      return response
    }, origin)
    await h.refresh(); await h.select('left', 'a'); await h.select('right', 'b')
    assert.match(h.el('left-outcome').textContent, /Decision: accepted/)
    assert.match(h.el('right-outcome').textContent, /Decision: rejected/)
    assert.match(h.el('left-history').textContent, /Import acknowledgement: unknown/)
    assert.match(h.el('left-history').textContent, /Named reviews \(1\)/)
    assert.match(h.el('comparison-status').textContent, /Matching verified baseline/)
    assert.match(h.el('comparison').textContent, /Distance \(m\).*A: 60/)
    const requestsBeforeExport = h.requests.length
    const inspectedA = h.el('left-raw').textContent, inspectedB = h.el('right-raw').textContent
    await h.el('dossier-export').dispatch('click')
    assert.equal(h.requests.length, requestsBeforeExport)
    assert.equal(h.downloads.length, 1)
    const portable = await verifyTrialComparisonDossier(h.downloads[0].json)
    for (const [index, exact] of [inspectedA, inspectedB].entries()) {
      const item = portable.envelope.observations[index]
      assert.deepEqual(JSON.parse(item.payload_json), JSON.parse(exact))
      assert.equal(item.payload_json, nativeBodies.get(origin + API + '/' + item.trial_id))
      assert.equal(item.payload_digest, 'sha256:' + hash(item.payload_json))
      assert.equal(JSON.parse(item.payload_json).record.import_request.dossier_text, envelopeText)
    }
    assert.equal(portable.envelope.manifest.readable_markdown_sha256, 'sha256:' + hash(h.downloads[0].markdown))
    assert.equal(portable.envelope.observations[0].trial_id, 'a')
    assert.equal(JSON.parse(portable.envelope.observations[0].payload_json).record.events.length, 2)
    assert.deepEqual(await filesSnapshot(root), initial)
    if (process.env.MOONROBO_TRIAL_PROOF) {
      await writeFile(path.join(journey, 'comparison.json'), h.downloads[0].json)
      await writeFile(path.join(journey, 'comparison.md'), h.downloads[0].markdown)
    }
    await h.select('right', 'c')
    assert.match(h.el('comparison-status').textContent, /Different or unverified baseline/)
    assert.ok(h.el('comparison').textContent.split('\n').every((line) => line.endsWith('Δ B−A: unavailable')))
    assert.deepEqual(await filesSnapshot(root), initial)
    await writeFile(path.join(root, 'robot.json'), 'Current artifact intentionally changed by test setup')
    const changed = await filesSnapshot(root)
    const oldReport = h.downloads[0].markdown
    await verifyTrialComparisonDossier(h.downloads[0].json)
    assert.equal(h.downloads[0].markdown, oldReport)
    assert.deepEqual(await filesSnapshot(root), changed)
    await h.select('left', 'a')
    assert.match(h.el('left-binding').textContent, /Current binding: blocked/)
    assert.match(h.el('left-outcome').textContent, /Decision: accepted/)
    assert.deepEqual(await filesSnapshot(root), changed)
    assert.ok(h.requests.every((request) => request.method === 'GET' && !request.body))
    const retained = path.join(root, '.moonsuite/products/moonrobo/proof-sessions/digital-trials')
    await writeFile(path.join(retained, 'b/head.json'), 'corrupt head retained by fixture')
    const corrupt = await filesSnapshot(root)
    await h.select('right', 'b')
    assert.match(h.el('right-status').textContent, /Unavailable/)
    assert.equal(h.el('right-raw').textContent, 'Unavailable')
    assert.equal(h.el('comparison').textContent, 'Unavailable')
    assert.deepEqual(await filesSnapshot(root), corrupt)
    await mkdir(path.join(retained, 'd-missing'))
    for (let i = 0; i < 35; i++) await mkdir(path.join(retained, `z-missing-${i}`))
    const overflow = await filesSnapshot(root)
    await h.refresh()
    assert.match(h.el('status').textContent, /Truncated/)
    assert.match(h.el('status').textContent, /32 shown/)
    assert.match(h.el('issues').textContent, /invalid-evidence/)
    assert.match(h.el('issues').textContent, /missing-evidence/)
    assert.deepEqual(await filesSnapshot(root), overflow)
    const proof = { native_http: true, production_asset: entry, production_asset_sha256: hash(asset), source_controller: 'mountDigitalTrials → mountRetainedTrials → createTrialComparisonDossier', requests: h.requests, fixture_root: root, store_bytes_preserved: true, changed_current_artifact_preserved: true, frozen_outcome_history_separate: true, different_verified_baseline_no_deltas: true, failed_second_side_cleared: true, native_count_limit_and_invalid_missing: true, portable_exact_native_payloads: true, portable_original_dossier_result_and_all_events: true, independent_node_sha256_payload_and_markdown: true, export_extra_requests: 0, portable_reopen_no_current_reads: true, browser_pixels: false, os_save_dialog: false }
    if (process.env.MOONROBO_TRIAL_PROOF) await writeFile(process.env.MOONROBO_TRIAL_PROOF, JSON.stringify(proof, null, 2) + '\n')
  } finally { child.kill('SIGTERM'); await new Promise((resolve) => { if (child.exitCode !== null) resolve(); else child.once('exit', resolve) }) }
})
const API = '/api/moonrobo/digital-trials'


const editor = (h, id) => h.root.querySelector(`#dt-${id}`)
test('R449 inspected rejected trial continues with a fresh GET; named review uses the fresh revision', async () => {
  const fresh = payload('a', 'rejected'); fresh.record.revision = 7
  fresh.record.import_request.session_id = 'session-a'
  const reviewed = structuredClone(fresh); reviewed.record.revision = 8
  const h = harness(queue(response(catalogue()), response(payload('a', 'rejected')), response(fresh), response(reviewed)))
  assert.equal(h.el('left-continue').disabled, true)
  await h.refresh(); await h.select('left', 'a')
  await h.el('left-continue').dispatch('click')
  assert.equal(editor(h, 'trial-id').value, 'a')
  assert.equal(editor(h, 'session-id').value, 'session-a')
  assert.match(editor(h, 'revision').textContent, /7/)
  assert.equal(h.requests.length, 3)
  assert.ok(h.requests.every((r) => r.method === 'GET'))
  assert.equal(h.requests[2].url, '/api/moonrobo/digital-trials/a')
  editor(h, 'event-id').value = 'review-a'
  editor(h, 'reviewer').value = 'Operator'
  editor(h, 'note').value = 'Reviewed digital rejection only'
  await editor(h, 'review').dispatch('click')
  const event = JSON.parse(h.requests[3].body)
  assert.equal(event.trial_id, 'a'); assert.equal(event.expected_revision, 7)
  assert.equal(event.kind, 'review')
})

test('R449 cancel keeps the unrelated editor draft; confirmed switch clears old files and notes only after a successful read', async () => {
  let allow = false, confirmations = 0
  const h = harness(queue(response(catalogue()), response(payload('a')), response(payload('a'))), '', {
    confirmReplace: () => { confirmations++; return allow },
  })
  editor(h, 'trial-id').value = 'old'
  editor(h, 'note').value = 'Keep this draft'
  editor(h, 'reviewer').value = 'Old reviewer'
  editor(h, 'proof-file').files = [{ name: 'old.json', arrayBuffer: async () => new TextEncoder().encode('old proof').buffer }]
  await editor(h, 'proof-file').dispatch('change')
  await h.refresh(); await h.select('left', 'a')
  await h.el('left-continue').dispatch('click')
  assert.equal(confirmations, 1); assert.equal(h.requests.length, 2)
  assert.equal(editor(h, 'trial-id').value, 'old'); assert.equal(editor(h, 'note').value, 'Keep this draft')
  assert.match(editor(h, 'proof-file-status').textContent, /loaded/)
  allow = true
  await h.el('left-continue').dispatch('click')
  assert.equal(confirmations, 2); assert.equal(editor(h, 'trial-id').value, 'a')
  assert.equal(editor(h, 'note').value, ''); assert.equal(editor(h, 'reviewer').value, '')
  assert.equal(editor(h, 'proof-file').files.length, 0)
  assert.equal(editor(h, 'proof-file-status').textContent, 'No file chosen')
  assert.ok(h.requests.every((r) => r.method === 'GET'))
})

test('R449 same-trial handoff keeps its draft and unknown acknowledgement requires explicit proof', async () => {
  const fresh = payload('a'); fresh.acknowledgement_state = 'unknown'; fresh.record.revision = 4
  const h = harness(queue(response(catalogue()), response(payload('a')), response(fresh)), '', {
    confirmReplace: () => { throw new Error('Same trial must not discard its draft') },
  })
  editor(h, 'trial-id').value = 'a'; editor(h, 'note').value = 'My pending note'
  await h.refresh(); await h.select('right', 'a'); await h.el('right-continue').dispatch('click')
  assert.equal(editor(h, 'note').value, 'My pending note')
  assert.match(editor(h, 'status').textContent, /unknown import acknowledgement/)
  assert.equal(editor(h, 'reconcile').disabled, false)
  assert.equal(editor(h, 'lost-ack').disabled, true)
  assert.ok(h.requests.every((r) => r.method === 'GET'))
})

test('R449 failed or wrong-identity handoff keeps drafts and disables stale event actions', async () => {
  for (const result of [response({}, 503), response(payload('wrong'))]) {
    const h = harness(queue(response(payload('old')), response(catalogue()), response(payload('a')), result), '', { confirmReplace: () => true })
    editor(h, 'trial-id').value = 'old'; editor(h, 'note').value = 'Preserve'
    await editor(h, 'reopen').dispatch('click')
    assert.equal(editor(h, 'review').disabled, false)
    await h.refresh(); await h.select('left', 'a'); await h.el('left-continue').dispatch('click')
    assert.equal(editor(h, 'trial-id').value, 'old'); assert.equal(editor(h, 'note').value, 'Preserve')
    assert.equal(editor(h, 'review').disabled, true); assert.equal(editor(h, 'export').disabled, true)
    assert.match(editor(h, 'status').textContent, /503|different trial/)
  }
})

test('R449 closing or changing selected evidence during handoff cannot replace the editor', async () => {
  for (const cancel of ['close', 'cancel', 'selection', 'refresh']) {
    let release
    const h = harness(queue(response(catalogue()), response(payload('a')), () => new Promise((resolve) => { release = resolve }), response(catalogue())))
    await h.refresh(); await h.select('left', 'a')
    const pending = h.el('left-continue').dispatch('click'); await Promise.resolve(); await Promise.resolve()
    assert.equal(typeof release, 'function')
    if (cancel === 'selection') await h.select('left', '')
    else if (cancel === 'refresh') await h.refresh()
    else await h.dialog.dispatch(cancel)
    release(response(payload('a'))); await pending
    assert.equal(editor(h, 'trial-id').value, '')
    assert.equal(editor(h, 'review').disabled, true)
    assert.match(editor(h, 'status').textContent, /cancelled/)
    assert.ok(h.requests.every((r) => r.method === 'GET'))
  }
})

test('R449 repeated continue while reading performs only one fresh request', async () => {
  let release
  const h = harness(queue(response(catalogue()), response(payload('a')), () => new Promise((resolve) => { release = resolve })))
  await h.refresh(); await h.select('left', 'a')
  const first = h.el('left-continue').dispatch('click'); await Promise.resolve(); await Promise.resolve()
  const second = h.el('left-continue').dispatch('click')
  assert.equal(h.requests.length, 3)
  release(response(payload('a'))); await Promise.all([first, second])
  assert.equal(h.requests.length, 3)
  assert.equal(editor(h, 'trial-id').value, 'a')
})
