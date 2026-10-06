import test from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { mountDigitalTrials, inspectDigitalTrial, readExactTrialFile, downloadTrialExport } from './digital-trials.js'

// Minimal DOM fixture: exercise the panel's actual listeners, disabled controls,
// text-only rendering, dialog lifecycle, and fetch boundary without a server or
// adding a browser/DOM dependency. This is not a browser visual qualification.
class Element {
  constructor() {
    this.listeners = new Map()
    this.value = ''
    this.textContent = ''
    this.dataset = {}
    this.attributes = new Map()
    this.disabled = false
    this.files = []
    this.open = false
  }
  addEventListener(type, listener) {
    const listeners = this.listeners.get(type) || []
    listeners.push(listener)
    this.listeners.set(type, listeners)
  }
  setAttribute(key, value) { this.attributes.set(key, value) }
  showModal() { this.open = true }
  close() { this.open = false }
  async dispatch(type) {
    if (this.disabled && type === 'click') return
    for (const listener of this.listeners.get(type) || []) await listener({ target: this })
  }
}

class Root extends Element {
  set innerHTML(value) {
    this.markup = value
    this.elements = new Map([...value.matchAll(/id="([^"]+)"/g)].map(([, id]) => [id, new Element()]))
  }
  get innerHTML() { return this.markup }
  querySelector(selector) {
    const element = this.elements.get(selector.slice(1))
    assert.ok(element, `The panel contains ${selector}`)
    return element
  }
}

const response = (payload, status = 200) => ({ ok: status >= 200 && status < 300, status, json: async () => payload })
const record = (id = 'trial-1', revision = 1, overrides = {}) => ({
  record: {
    contract_id: 'moonrobo.digital-trial.v1',
    revision,
    import_request: { trial_id: id, session_id: 'session-1', dossier_text: 'envelope', result_text: 'result' },
    binding: { trial_id: id, attempt_id: 'attempt-frozen-1', calibration: null },
    events: [],
  },
  state: 'unknown',
  digital_result_state: 'digital-ready',
  binding_state: 'unknown',
  acknowledgement_state: 'confirmed',
  physical_execution_allowed: false,
  automatic_retry_allowed: false,
  blockers: [],
  unknowns: ['Calibration is absent or unqualified'],
  retention_state: 'pending-book-review',
  ...overrides,
})
const file = (name, text) => ({ name, arrayBuffer: async () => new TextEncoder().encode(text).buffer })

function harness(responses = []) {
  const root = new Root()
  const dialog = new Element()
  const launcher = new Element()
  const requests = []
  const downloads = []
  const api = mountDigitalTrials({
    root, dialog, launcher,
    hostUrl: 'https://host.invalid/moonrobo/',
    now: () => 123456,
    fetchImpl: async (url, options) => {
      requests.push({ url, ...options, parsedBody: options.body ? JSON.parse(options.body) : undefined })
      const next = responses.shift()
      if (next instanceof Error) throw next
      if (typeof next === 'function') return next()
      assert.ok(next, 'Every fetch has an explicitly mocked response')
      return next
    },
    download: (payload, id) => downloads.push({ payload, id }),
  })
  const el = (id) => root.querySelector(`#dt-${id}`)
  const fill = async (id, value) => { el(id).value = value; await el(id).dispatch('input') }
  const choose = async (kind, selected) => {
    el(`${kind}-file`).files = selected ? [selected] : []
    await el(`${kind}-file`).dispatch('change')
  }
  const click = async (id) => { await el(id).dispatch('click'); await api.whenIdle() }
  return { root, dialog, launcher, requests, downloads, api, el, fill, choose, click }
}

async function importDraft(h) {
  await h.fill('trial-id', 'trial-1')
  await h.fill('session-id', 'session-1')
  await h.choose('dossier', file('dossier.json', '\uFEFF{ "envelope": true }\r\n'))
  await h.choose('result', file('result.json', '{ "digital": "result" }\r\n'))
}

test('cockpit launcher and bootstrap wire a separate inert panel with no eager fetch', async () => {
  const h = harness()
  const html = await readFile(new URL('./index.html', import.meta.url), 'utf8')
  const bootstrap = await readFile(new URL('./bootstrap.js', import.meta.url), 'utf8')
  assert.match(html, /id="app"><\/div>/)
  assert.match(html, /id="digital-trials-open"/)
  assert.match(html, /<dialog id="digital-trials-dialog"/)
  assert.match(bootstrap, /mountDigitalTrials\(\{/)
  assert.equal(h.requests.length, 0)
  assert.equal(h.el('trial-id').value, '')
  assert.equal(h.el('session-id').value, '')
  assert.equal(h.el('review').disabled, true)
  assert.equal(h.el('export').disabled, true)
  assert.match(h.root.markup, /Local physical authority: <strong>false<\/strong>/)
  await h.launcher.dispatch('click')
  assert.equal(h.dialog.open, true)
  await h.click('close')
  assert.equal(h.dialog.open, false)
  assert.equal(h.requests.length, 0)
})

test('import sends the exact frozen file strings, IDs, and only the inert endpoint', async () => {
  const h = harness([response(record())])
  await importDraft(h)
  await h.click('import')
  assert.equal(h.requests.length, 1)
  assert.equal(h.requests[0].url, 'https://host.invalid/moonrobo/api/moonrobo/digital-trials/import')
  assert.equal(h.requests[0].method, 'POST')
  assert.equal(h.requests[0].cache, 'no-store')
  assert.deepEqual(h.requests[0].parsedBody, {
    trial_id: 'trial-1', session_id: 'session-1',
    dossier_text: '\uFEFF{ "envelope": true }\r\n',
    result_text: '{ "digital": "result" }\r\n',
  })
  assert.equal(h.el('state').textContent, 'Digital-only state: unknown')
  assert.match(h.el('evidence-state').textContent, /Digital result: digital-ready/)
  assert.match(h.el('calibration').textContent, /Calibration is absent or unqualified/)
  assert.match(h.el('revision').textContent, /1/)
  assert.equal(h.el('review').disabled, false, 'Named notes remain possible without elevating unknown calibration')
  assert.equal(h.el('reconcile').disabled, true, 'Reconciliation cannot resolve missing calibration')
})

test('empty import and incomplete review are rejected locally', async () => {
  const h = harness([response(record())])
  await h.click('import')
  assert.match(h.el('status').textContent, /Enter a trial ID/)
  await h.fill('trial-id', 'trial-1')
  await h.click('import')
  assert.match(h.el('status').textContent, /session ID/)
  await h.fill('session-id', 'session-1')
  await h.click('import')
  assert.match(h.el('status').textContent, /Choose both/)
  assert.equal(h.requests.length, 0)
  await h.click('reopen')
  await h.fill('event-id', 'note-1')
  await h.fill('reviewer', 'Alice')
  await h.click('review')
  assert.match(h.el('status').textContent, /reviewer name and a review note/)
  assert.equal(h.requests.length, 1)
})

test('network loss keeps draft, marks uncertainty, and requires explicit re-open without retry', async () => {
  const h = harness([new Error('Connection lost'), response(record('trial-1', 3)), response(record('trial-1', 4))])
  await importDraft(h)
  await h.fill('reviewer', 'Named reviewer')
  await h.fill('note', 'Keep this exact draft.\nSecond line.')
  await h.fill('event-id', 'review-event-1')
  await h.click('import')
  assert.equal(h.requests.length, 1)
  assert.equal(h.el('import').disabled, true)
  assert.equal(h.el('review').disabled, true)
  assert.equal(h.el('state').dataset.state, 'unknown')
  assert.match(h.el('status').textContent, /No automatic retry/)
  await h.click('close')
  await h.launcher.dispatch('click')
  assert.equal(h.el('note').value, 'Keep this exact draft.\nSecond line.')
  assert.equal(h.el('dossier-file').files[0].name, 'dossier.json')
  await h.click('import')
  assert.equal(h.requests.length, 1)
  await h.click('reopen')
  assert.equal(h.requests.length, 2)
  assert.equal(h.requests[1].method, 'GET')
  assert.equal(h.el('review').disabled, false)
  await h.click('review')
  assert.equal(h.requests.length, 3)
  assert.deepEqual(h.requests[2].parsedBody, {
    trial_id: 'trial-1', expected_revision: 3, event_id: 'review-event-1',
    kind: 'review', proof_text: '', reviewer: 'Named reviewer',
    note: 'Keep this exact draft.\nSecond line.', now_ms: '123456',
  })
  assert.match(h.el('status').textContent, /No authority was granted/)
})

test('HTTP conflict preserves files and review draft and blocks stale event repetition', async () => {
  const h = harness([response(record()), response({ code: 'digital-trial-event-unconfirmed', path: 'trial-1', message: 'stale revision' }, 409), response({ message: 'unavailable' }, 503)])
  await importDraft(h)
  await h.click('reopen')
  await h.fill('event-id', 'review-1')
  await h.fill('reviewer', 'A. Reviewer')
  await h.fill('note', 'Do not erase.')
  await h.click('review')
  assert.match(h.el('status').textContent, /409.*stale revision/)
  assert.equal(h.el('note').value, 'Do not erase.')
  assert.equal(h.el('review').disabled, true)
  await h.click('reopen')
  assert.equal(h.requests.length, 3)
  assert.equal(h.el('review').disabled, true)
  assert.equal(h.el('note').value, 'Do not erase.')
})

test('lost acknowledgement and manual reconciliation stay on the same attempt', async () => {
  const h = harness([
    response(record('trial-1', 1, { state: 'digital-ready', binding_state: 'matched' })),
    response(record('trial-1', 2, { acknowledgement_state: 'unknown' })),
    response(record('trial-1', 3)),
  ])
  await h.fill('trial-id', 'trial-1')
  await h.click('reopen')
  await h.fill('event-id', 'lost-1')
  await h.fill('note', 'The inert import acknowledgement was lost.')
  await h.click('lost-ack')
  assert.deepEqual(h.requests[1].parsedBody, {
    trial_id: 'trial-1', expected_revision: 1, event_id: 'lost-1', kind: 'lost-ack',
    proof_text: '', reviewer: '', note: 'The inert import acknowledgement was lost.', now_ms: '123456',
  })
  assert.equal(h.el('state').dataset.state, 'unknown')
  assert.equal(h.el('lost-ack').disabled, true)
  assert.match(h.el('status').textContent, /inert import acknowledgement/)
  await h.fill('event-id', 'proof-1')
  await h.click('reconcile')
  assert.equal(h.requests.length, 2)
  assert.match(h.el('status').textContent, /exact frozen result/)
  await h.choose('proof', file('original-result.json', '\uFEFF{ "frozen": true }\r\n'))
  await h.fill('reviewer', 'Proof reviewer')
  await h.fill('note', 'Compared the exact frozen result for this attempt.')
  await h.click('reconcile')
  assert.deepEqual(h.requests[2].parsedBody, {
    trial_id: 'trial-1', expected_revision: 2, event_id: 'proof-1', kind: 'reconcile',
    proof_text: '\uFEFF{ "frozen": true }\r\n', reviewer: 'Proof reviewer', note: 'Compared the exact frozen result for this attempt.', now_ms: '123456',
  })
  assert.equal(h.el('state').textContent, 'Digital-only state: unknown', 'Reconciliation must not clear absent calibration locally')
  assert.equal(h.requests.every(({ url }) => url.includes('/digital-trials/')), true)
})

test('a rejected reconciliation leaves the frozen proof selected and never retries', async () => {
  const h = harness([response(record('trial-1', 2, { acknowledgement_state: 'unknown' })), response({ error: 'proof mismatch' }, 400)])
  await h.fill('trial-id', 'trial-1')
  await h.click('reopen')
  await h.fill('event-id', 'proof-1')
  await h.fill('reviewer', 'Proof reviewer')
  await h.fill('note', 'Check this candidate proof.')
  await h.choose('proof', file('wrong.json', '{ "wrong": true }'))
  await h.click('reconcile')
  assert.match(h.el('status').textContent, /proof mismatch/)
  assert.equal(h.el('proof-file').files[0].name, 'wrong.json')
  assert.equal(h.el('reconcile').disabled, true)
  assert.equal(h.requests.length, 2)
})

test('re-open safely encodes IDs and changing the ID discards the previous inspection only', async () => {
  const id = 'trial /?query#fragment'
  const h = harness([response(record(id))])
  await h.fill('trial-id', id)
  await h.fill('note', 'Keep draft')
  await h.click('reopen')
  assert.equal(h.requests[0].url, `https://host.invalid/moonrobo/api/moonrobo/digital-trials/${encodeURIComponent(id)}`)
  await h.fill('trial-id', 'another-trial')
  assert.equal(h.el('export').disabled, true)
  assert.equal(h.el('review').disabled, true)
  assert.match(h.el('inspection').textContent, /No host record/)
  assert.equal(h.el('note').value, 'Keep draft')
})

test('mismatched records, invalid revisions, and absent records are not trusted', () => {
  assert.throws(() => inspectDigitalTrial(record('different'), 'trial-1'), /different trial/)
  assert.throws(() => inspectDigitalTrial(record('trial-1', '1'), 'trial-1'), /revision/)
  assert.throws(() => inspectDigitalTrial(record('trial-1', -1), 'trial-1'), /revision/)
  assert.throws(() => inspectDigitalTrial({}, 'trial-1'), /no digital-trial record/)
  const wrongContract = record()
  wrongContract.record.contract_id = 'other-contract'
  assert.throws(() => inspectDigitalTrial(wrongContract, 'trial-1'), /unsupported/)
  const wrongBinding = record()
  wrongBinding.record.binding.trial_id = 'different'
  assert.throws(() => inspectDigitalTrial(wrongBinding, 'trial-1'), /different trial/)
  const inspection = inspectDigitalTrial(record('trial-1', 1, { state: 'physically-ready', physical_execution_allowed: true }), 'trial-1')
  assert.equal(inspection.state, 'unknown')
  assert.equal(inspection.physicalAuthority, false)
})

test('server content is rendered as text; digital-ready remains explicitly digital-only', async () => {
  const warning = '<img src=x onerror="alert(1)">'
  const h = harness([response(record('trial-1', 8, { state: 'digital-ready', unknowns: [warning] }))])
  await h.fill('trial-id', 'trial-1')
  await h.click('reopen')
  assert.equal(h.el('state').textContent, 'Digital-only state: digital-ready')
  assert.match(h.el('inspection').textContent, /<img/)
  assert.match(h.el('calibration').textContent, /<img/)
  assert.equal(h.root.markup.includes(warning), false)
  assert.match(h.root.markup, /Local physical authority: <strong>false/)
})

test('export downloads the complete host response and keeps Book retention pending', async () => {
  const exported = {
    contract_id: 'moonrobo.digital-incident-export.v1',
    submission: { product_id: 'moonrobo', outcome_id: 'trial-1' },
    evidence: [{ reference_id: 'result-1', text: 'frozen exact text', digest: 'digest' }],
    retention_state: 'pending-book-review', physical_execution_allowed: false,
  }
  const h = harness([response(record()), response(exported)])
  await h.fill('trial-id', 'trial-1')
  await h.click('reopen')
  await h.click('export')
  assert.deepEqual(h.requests[1].parsedBody, { trial_id: 'trial-1' })
  assert.equal(h.requests[1].url.endsWith('/digital-trials/export'), true)
  assert.deepEqual(h.downloads, [{ payload: exported, id: 'trial-1' }])
  assert.match(h.el('export-status').textContent, /retention remains pending/)
  assert.match(h.el('export-status').textContent, /no Book acknowledgement/)
  assert.deepEqual(JSON.parse(h.el('export-preview').textContent), exported)
  assert.equal(h.requests.length, 2)
})

test('download helper emits JSON and releases its temporary link', async () => {
  let blob
  const clicks = []
  const removed = []
  const revoked = []
  const link = { click() { clicks.push(this.download) }, remove() { removed.push(true) } }
  const document = { createElement: (tag) => { assert.equal(tag, 'a'); return link }, body: { appendChild: (value) => assert.equal(value, link) } }
  const url = { createObjectURL(value) { blob = value; return 'blob:local' }, revokeObjectURL(value) { revoked.push(value) } }
  downloadTrialExport({ retention_state: 'pending-book-review' }, '../trial/name', document, url)
  assert.equal(blob.type, 'application/json')
  assert.deepEqual(JSON.parse(await blob.text()), { retention_state: 'pending-book-review' })
  assert.deepEqual(clicks, ['digital-trial-___trial_name-pending-book.json'])
  assert.deepEqual(removed, [true])
  assert.deepEqual(revoked, ['blob:local'])
})

test('a malformed export cannot produce a download or retention acknowledgement', async () => {
  const h = harness([response(record()), response({ retention_state: 'retained', physical_execution_allowed: true })])
  await h.fill('trial-id', 'trial-1')
  await h.click('reopen')
  await h.click('export')
  assert.equal(h.downloads.length, 0)
  assert.match(h.el('status').textContent, /No download or Book acknowledgement/)
  assert.match(h.el('export-status').textContent, /pending/)
})

test('failed re-open does not leave an earlier revision actionable', async () => {
  const h = harness([response(record()), new Error('Read disconnected')])
  await h.fill('trial-id', 'trial-1')
  await h.fill('note', 'Keep the review draft')
  await h.click('reopen')
  assert.equal(h.el('review').disabled, false)
  await h.click('reopen')
  assert.equal(h.el('review').disabled, true)
  assert.equal(h.el('export').disabled, true)
  assert.equal(h.el('state').dataset.state, 'unknown')
  assert.equal(h.el('note').value, 'Keep the review draft')
  assert.equal(h.requests.length, 2)
})

test('the host requires an explanation for loss and a named reviewer for proof', async () => {
  const h = harness([response(record()), response(record('trial-1', 2, { acknowledgement_state: 'unknown' }))])
  await h.fill('trial-id', 'trial-1')
  await h.fill('event-id', 'event-1')
  await h.click('reopen')
  await h.click('lost-ack')
  assert.equal(h.requests.length, 1)
  assert.match(h.el('status').textContent, /explanation/)
  await h.click('reopen')
  await h.choose('proof', file('proof.json', '{}'))
  await h.fill('note', 'Exact bytes checked')
  await h.click('reconcile')
  assert.equal(h.requests.length, 2)
  assert.match(h.el('status').textContent, /reviewer name/)
})

test('exact-file reading preserves BOM and CRLF and rejects invalid UTF-8', async () => {
  const content = '\uFEFF{ "value": "🛰" }\r\n'
  assert.equal(await readExactTrialFile(file('file.json', content)), content)
  await assert.rejects(readExactTrialFile({ arrayBuffer: async () => Uint8Array.from([0xff, 0xfe]).buffer }), /encoded data/)
})

test('invalid or deselected files cannot reuse a previously loaded payload', async () => {
  const h = harness()
  await importDraft(h)
  await h.choose('result', { name: 'bad.json', arrayBuffer: async () => Uint8Array.from([0xff]).buffer })
  await h.click('import')
  assert.equal(h.requests.length, 0)
  assert.match(h.el('status').textContent, /Choose both/)
  await h.choose('result', file('valid.json', '{}'))
  await h.choose('result', null)
  await h.click('import')
  assert.equal(h.requests.length, 0)
})

test('busy requests prevent a second action without clearing editable drafts', async () => {
  let release
  const h = harness([() => new Promise((resolve) => { release = resolve })])
  await importDraft(h)
  const pending = h.click('import')
  await Promise.resolve()
  await Promise.resolve()
  assert.equal(h.el('import').disabled, true)
  assert.equal(h.el('trial-id').disabled, true)
  assert.equal(h.root.attributes.get('aria-busy'), 'true')
  await h.el('import').dispatch('click')
  assert.equal(h.requests.length, 1)
  release(response(record()))
  await pending
  assert.equal(h.el('trial-id').disabled, false)
  assert.equal(h.el('session-id').value, 'session-1')
})

test('a slow earlier file read never replaces the newest chosen result', async () => {
  let release
  const h = harness([response(record())])
  await importDraft(h)
  const oldRead = h.choose('result', { name: 'old.json', arrayBuffer: () => new Promise((resolve) => { release = resolve }) })
  await h.choose('result', file('new.json', '{"new":true}\n'))
  assert.equal(h.el('import').disabled, true, 'Wait for outstanding reads without sending either draft')
  release(new TextEncoder().encode('{"old":true}').buffer)
  await oldRead
  assert.match(h.el('result-file-status').textContent, /new.json/)
  await h.click('import')
  assert.equal(h.requests[0].parsedBody.result_text, '{"new":true}\n')
})
