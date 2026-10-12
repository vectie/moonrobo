import test from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { createHash, webcrypto } from 'node:crypto'
import { mountDesignWorkbench, parseDesignFields, excavationDraft, inspectSimulationInput, downloadSimulationInput } from './design-workbench.js'

globalThis.crypto ||= webcrypto
// Actual native producer output, frozen after the focused MoonBit tests. These
// are function/DOM fixtures, not browser, live UI, robot or provider tests.
const built = JSON.parse(await readFile(new URL('../../fixtures/design-workbench-built-view.json', import.meta.url), 'utf8'))
const envelope = JSON.parse(await readFile(new URL('../../fixtures/design-workbench-simulation-input.json', import.meta.url), 'utf8'))
const library = JSON.parse(await readFile(new URL('../../fixtures/design-library-roundtrip.json', import.meta.url), 'utf8'))
const draftView = () => ({ ...structuredClone(built), state: 'draft', package: null })
const response = (payload, status = 200) => ({ ok: status === 200, status, json: async () => payload })
class Element {
  constructor() { this.listeners = new Map(); this.value = ''; this.disabled = false; this.dataset = {}; this.textContent = ''; this.open = false; this.attributes = new Map() }
  addEventListener(event, fn) { this.listeners.set(event, [...(this.listeners.get(event) || []), fn]) }
  async dispatch(event) { if (this.disabled && event === 'click') return; for (const fn of this.listeners.get(event) || []) await fn({ target: this }) }
  setAttribute(name, value) { this.attributes.set(name, value) }
  showModal() { this.open = true }
  close() { this.open = false }
  replaceChildren(...children) { this.children = children; this.value = children[0]?.value || '' }
}
class Root extends Element {
  constructor() { super(); this.ownerDocument = { createElement: () => new Element() } }
  set innerHTML(text) { this.markup = text; this.elements = new Map([...text.matchAll(/id="([^"]+)"/g)].map(([, id]) => [id, new Element()])) }
  querySelector(selector) { const element = this.elements.get(selector.slice(1)); assert.ok(element, selector); return element }
}
function harness(responses = [], confirmReplace = () => true) {
  const root = new Root(), dialog = new Element(), launcher = new Element(), requests = [], downloads = []
  const api = mountDesignWorkbench({ root, dialog, launcher, confirmReplace, hostUrl: 'https://host.invalid/moonrobo/', now: () => '2026-10-06T16:00:00Z',
    fetchImpl: async (url, options) => { requests.push({ url, ...options, parsed: JSON.parse(options.body) }); const result = responses.shift(); if (result instanceof Error) throw result; if (typeof result === 'function') return result(); assert.ok(result, 'Explicit response required'); return result },
    download: (payload, id, revision) => downloads.push({ payload, id, revision }),
  })
  const el = (id) => root.querySelector(`#dw-${id}`)
  const click = async (id) => { await el(id).dispatch('click'); await api.whenIdle() }
  const fill = async (id, value) => { el(id).value = value; await el(id).dispatch('input') }
  const choose = async (id, value) => { el(id).value = value; await el(id).dispatch('change') }
  return { root, dialog, launcher, requests, downloads, api, el, click, fill, choose }
}
async function select(h) { await h.fill('id', 'excavation-haul'); await h.fill('revision', 'r1') }

test('R8 actual producer package verifies every source and exact robot binding', async () => {
  const packet = await inspectSimulationInput(envelope, 'excavation-haul', 'r1')
  assert.equal(packet.sources.length, 8)
  assert.deepEqual(built.package, envelope)
  assert.equal(JSON.parse(packet.sources.find((s) => s.artifact_ref === packet.integration_receipt_ref).text).operation_id, 'robot.integrate-digital-model')
  assert.equal(packet.robot_artifact.physical_transport_enabled, false)
  assert.match(packet.limitations.join(' '), /not general CAD/)
})

test('R8 cockpit wires the bounded editor with no eager fetch and accessible controls', async () => {
  const h = harness()
  const html = await readFile(new URL('./index.html', import.meta.url), 'utf8'), bootstrap = await readFile(new URL('./bootstrap.js', import.meta.url), 'utf8')
  assert.match(html, /id="design-workbench-open"/); assert.match(bootstrap, /mountDesignWorkbench\(\{/)
  assert.equal(h.requests.length, 0); assert.equal(h.el('build').disabled, true); assert.equal(h.el('export').disabled, true)
  assert.match(h.root.markup, /physical authority: <strong>false/)
  assert.match(h.root.markup, /does not run your mission scenarios/)
  await h.launcher.dispatch('click'); assert.equal(h.dialog.open, true)
  await h.click('template'); await h.fill('name', 'My draft'); await h.click('close'); await h.launcher.dispatch('click')
  assert.equal(h.el('name').value, 'My draft'); assert.equal(h.requests.length, 0)
})

test('R8 full editor save build export path consumes actual producer responses', async () => {
  const h = harness([response(draftView()), response(built), response(envelope)])
  await h.click('template'); await h.click('save')
  assert.deepEqual(h.requests[0].parsed, { design: excavationDraft(), recorded_at: '2026-10-06T16:00:00Z' })
  assert.equal(h.el('build').disabled, false)
  await h.click('build')
  assert.equal(h.requests[1].parsed.expected_digest, built.draft.design_digest)
  assert.equal(h.el('build').disabled, true); assert.equal(h.el('export').disabled, false)
  await h.click('export')
  assert.deepEqual(h.downloads, [{ payload: envelope, id: 'excavation-haul', revision: 'r1' }])
  assert.match(h.el('export-status').textContent, /no simulation was run/)
  assert.deepEqual(h.requests.map((r) => r.url), ['save', 'build', 'export'].map((op) => `https://host.invalid/moonrobo/api/moonrobo/design-workbench/${op}`))
})

test('R8 editing saved revision disables build and export until a fresh save', async () => {
  const h = harness([response(built)])
  await select(h); await h.click('open'); await h.fill('max', '0.2')
  assert.equal(h.el('build').disabled, true); assert.equal(h.el('export').disabled, true)
  await h.fill('revision', 'r2')
  assert.equal(h.el('max').value, '0.2'); assert.equal(h.el('save').disabled, false)
})

test('R8 failed save keeps fields, marks outcome uncertain and requires explicit re-open', async () => {
  const h = harness([new Error('Connection lost'), response(draftView())])
  await h.click('template'); await h.click('save')
  assert.equal(h.el('steps').value, excavationDraft().task_loop.join('\n'))
  assert.match(h.el('status').textContent, /no retry was made/)
  assert.equal(h.el('save').disabled, true); assert.equal(h.el('build').disabled, true)
  await h.click('save'); assert.equal(h.requests.length, 1)
  await h.click('open'); assert.equal(h.el('build').disabled, false)
})

test('R8 partial builds stay unconfirmed and cannot export or automatically retry', async () => {
  const h = harness([response({ ...draftView(), state: 'unconfirmed', message: 'Partial build preserved' })])
  await select(h); await h.click('open')
  assert.equal(h.el('save').disabled, true); assert.equal(h.el('build').disabled, true); assert.equal(h.el('export').disabled, true)
  assert.match(h.el('status').textContent, /Partial build preserved/)
})

test('R8 failed re-open cannot leave prior build actionable', async () => {
  const h = harness([response(built), new Error('No readable host response')])
  await select(h); await h.click('open'); await h.click('open')
  assert.equal(h.el('export').disabled, true); assert.equal(h.el('build').disabled, true)
  assert.equal(h.el('id').value, 'excavation-haul')
})

test('R8 repeated actions are single-flight and close suppresses stale build callbacks', async () => {
  let release
  const h = harness([response(draftView()), () => new Promise((resolve) => { release = resolve })])
  await select(h); await h.click('open')
  const pending = h.click('build'); await Promise.resolve(); await Promise.resolve()
  assert.equal(h.el('build').disabled, true); assert.equal(h.el('id').disabled, true)
  await h.el('build').dispatch('click'); assert.equal(h.requests.length, 2)
  await h.el('close').dispatch('click'); release(response(built)); await pending
  assert.equal(h.el('export').disabled, true); assert.match(h.el('state').textContent, /unconfirmed/)
  assert.equal(h.downloads.length, 0)
})

test('R8 close and newer selection suppress stale export downloads', async () => {
  let release
  const h = harness([response(built), () => new Promise((resolve) => { release = resolve })])
  await select(h); await h.click('open')
  const pending = h.click('export'); await Promise.resolve(); await Promise.resolve()
  await h.el('close').dispatch('click'); await h.fill('revision', 'r2')
  release(response(envelope)); await pending
  assert.equal(h.downloads.length, 0); assert.equal(h.el('revision').value, 'r2'); assert.equal(h.el('export').disabled, true)
})

test('R8 Escape during save suppresses the callback and a later re-open reconciles it', async () => {
  let release
  const h = harness([() => new Promise((resolve) => { release = resolve }), response(draftView())])
  await h.click('template')
  const pending = h.click('save'); await Promise.resolve(); await Promise.resolve()
  await h.dialog.dispatch('cancel'); release(response(draftView())); await pending
  assert.equal(h.el('build').disabled, true); assert.equal(h.el('save').disabled, true)
  await h.click('open')
  assert.equal(h.el('build').disabled, false); assert.equal(h.requests.length, 2)
})

test('R8 newer selection wins over an earlier re-open response', async () => {
  let release
  const h = harness([() => new Promise((resolve) => { release = resolve })])
  await select(h)
  const pending = h.click('open'); await Promise.resolve(); await Promise.resolve()
  await h.fill('revision', 'r2'); release(response(built)); await pending
  assert.equal(h.el('revision').value, 'r2'); assert.equal(h.el('export').disabled, true)
  assert.equal(h.el('preview').textContent.includes('generated_sources'), false)
})

test('R8 mismatched host selection is rejected and host text never becomes markup', async () => {
  const bad = structuredClone(built); bad.draft.revision = 'other'
  const h = harness([response(bad)])
  await select(h); await h.click('open'); assert.match(h.el('status').textContent, /different or unsupported/)
  const draft = excavationDraft(); draft.mission.name = '<img src=x onerror=alert(1)>'
  const view = draftView(); view.draft.design_text = JSON.stringify(draft); view.draft.design_digest = 'sha256:' + createHash('sha256').update(view.draft.design_text).digest('hex')
  const h2 = harness([response(view)]); await select(h2); await h2.click('open')
  assert.match(h2.el('preview').textContent, /<img/); assert.equal(h2.root.markup.includes('<img'), false)
})

test('R8 package tampering and self-consistently rehashed wrong source binding fail', async () => {
  await assert.rejects(inspectSimulationInput({ ...envelope, package_json: envelope.package_json + ' ' }, 'excavation-haul', 'r1'), /digest/)
  const packet = JSON.parse(envelope.package_json); packet.robot_artifact.robot_json_sha256 = '0'.repeat(64)
  const text = JSON.stringify(packet), bad = { ...envelope, package_json: text, package_digest: 'sha256:' + createHash('sha256').update(text).digest('hex') }
  await assert.rejects(inspectSimulationInput(bad, 'excavation-haul', 'r1'), /binding mismatch/)
  const h = harness([response(built), response(bad)]); await select(h); await h.click('open'); await h.click('export')
  assert.equal(h.downloads.length, 0)
})

test('R8 field validation is bounded and rejects nonfinite speed empty evidence and duplicate mechanisms', () => {
  const d = excavationDraft(), values = { id: d.design_id, revision: d.revision, name: d.mission.name, steps: d.task_loop.join('\n'), mechanisms: d.mechanisms.map((m) => `${m.id}|${m.kind}`).join('\n'), scenarios: d.validation.scenarios.map((s) => `${s.id}|${s.expected}`).join('\n'), min: '0.01', max: '0.1' }
  assert.deepEqual(parseDesignFields(values), d)
  for (const change of [{ max: 'Infinity' }, { max: '0.6' }, { min: '' }, { steps: 'only one' }, { id: '../escape' }, { mechanisms: 'same|a\nsame|b\nother|c' }, { scenarios: 'a|\nb|value\nc|value' }]) assert.throws(() => parseDesignFields({ ...values, ...change }))
})

test('R8 download helper emits complete envelope and cleans up its object URL', async () => {
  let blob, clicked = false, removed = false, revoked
  const link = { click() { clicked = true }, remove() { removed = true } }
  downloadSimulationInput(envelope, '../id', 'r/1', { createElement: () => link, body: { appendChild: () => {} } }, { createObjectURL(value) { blob = value; return 'blob:fixture' }, revokeObjectURL(value) { revoked = value } })
  assert.deepEqual(JSON.parse(await blob.text()), envelope); assert.equal(clicked && removed, true); assert.equal(revoked, 'blob:fixture'); assert.equal(link.download, 'moonrobo-___id-r_1-simulation-input.json')
})

async function librarySelection(h, right = 'r2') {
  await h.click('catalogue')
  await h.choose('left', 'excavation-haul/r1')
  await h.choose('right', `excavation-haul/${right}`)
}

test('R20 shipped controller native save catalogue compare fork explicit save roundtrip', async () => {
  const h = harness([response(library.catalogue), response(library.left), response(library.right), response(library.right), response(library.fork)])
  await librarySelection(h); await h.click('compare')
  assert.match(h.el('diff-loop').textContent, /Changed · Step 1\nA: Excavate a bounded scoop\nB: Dig a shallow scoop/)
  assert.match(h.el('diff-mechanisms').textContent, /B: shallow-scoop/)
  assert.match(h.el('diff-scenarios').textContent, /B: One shallow delivery completes/)
  assert.match(h.el('diff-speed').textContent, /A: 0.1\nB: 0.2/)
  assert.match(h.el('comparison-status').textContent, /5 changed fields/)
  assert.equal(h.el('steps').value, '')
  await h.choose('fork-source', 'right'); await h.fill('fork-revision', 'r3'); await h.click('fork')
  assert.equal(h.requests.length, 4); assert.ok(h.requests.every((r) => /\/(catalogue|open)$/.test(r.url)))
  assert.equal(h.el('revision').value, 'r3'); assert.equal(h.el('max').value, '0.2')
  assert.equal(h.el('build').disabled, true); assert.equal(h.el('export').disabled, true)
  assert.match(h.el('status').textContent, /nothing was written or built/)
  await h.click('save')
  assert.deepEqual(h.requests[4].parsed.design, JSON.parse(library.fork.draft.design_text))
  assert.equal(h.el('build').disabled, false); assert.equal(h.downloads.length, 0)
})

test('R20 refresh and comparison preserve unsaved fields, cancelled replacement preserves all fields', async () => {
  let confirmations = 0
  const h = harness([response(library.catalogue), response(library.left), response(library.right)], () => { confirmations++; return false })
  await h.click('template'); await h.fill('name', 'Keep my unsaved design')
  await librarySelection(h); await h.click('compare'); await h.fill('fork-revision', 'r3'); await h.click('fork')
  await h.click('open'); await h.click('template')
  assert.equal(confirmations, 3); assert.equal(h.requests.length, 3)
  assert.equal(h.el('name').value, 'Keep my unsaved design'); assert.equal(h.el('revision').value, 'r1')
  assert.equal(h.el('save').disabled, false)
})

test('R20 same and repeated comparison revalidate read-only and have no differences', async () => {
  const h = harness([response(library.catalogue), response(library.left), response(library.left)])
  await librarySelection(h, 'r1'); await h.click('compare'); await h.click('compare')
  assert.equal(h.requests.length, 3)
  assert.match(h.el('comparison-status').textContent, /0 changed fields.*Same saved revision selected twice/)
  await h.fill('fork-revision', 'r1'); await h.click('fork')
  assert.match(h.el('status').textContent, /different from the source/)
  await h.fill('fork-revision', 'r2'); await h.click('fork')
  assert.match(h.el('status').textContent, /already exists/)
  assert.equal(h.requests.length, 3)
})

test('R20 refreshing retains identities but requires fresh inspection and page reload rediscovers library', async () => {
  const h = harness([response(library.catalogue), response(library.left), response(library.right), response(library.catalogue)])
  await librarySelection(h); await h.click('compare'); await h.click('catalogue')
  assert.equal(h.el('left').value, 'excavation-haul/r1'); assert.equal(h.el('right').value, 'excavation-haul/r2')
  assert.equal(h.el('diff-loop').textContent, ''); assert.equal(h.el('fork').disabled, true)
  const reloaded = harness([response(library.catalogue)])
  assert.equal(reloaded.requests.length, 0); await librarySelection(reloaded)
  assert.equal(reloaded.el('compare').disabled, false)
})

test('R20 empty unavailable partial corrupt and missing entries are explicit and inert', async () => {
  const entries = [
    { ...library.catalogue.entries[0], state: 'unconfirmed', message: 'Partial build; preserve evidence.' },
    ...['missing-draft', 'corrupt-or-unreadable-draft'].map((state, i) => ({ ...library.catalogue.entries[1], revision: `bad-${i}`, state, selectable: false, design_digest: '', message: state })),
  ]
  const h = harness([response({ ...library.catalogue, entries: [], truncated: false }), response({ ...library.catalogue, entries, truncated: true }), new Error('unavailable')])
  await h.click('catalogue'); assert.match(h.el('library-status').textContent, /No saved revisions/); assert.equal(h.el('compare').disabled, true)
  await h.click('catalogue'); assert.match(h.el('library-status').textContent, /limit reached/)
  assert.match(h.el('library-issues').textContent, /Partial build/); assert.match(h.el('library-issues').textContent, /missing-draft/)
  assert.deepEqual(h.el('left').children.map((entry) => entry.disabled), [false, false, true, true])
  await h.click('catalogue'); assert.match(h.el('library-status').textContent, /unavailable/); assert.equal(h.el('fork').disabled, true)
  assert.equal(h.downloads.length, 0)
})

test('R20 partial build draft remains comparable and forkable without granting export', async () => {
  const partial = { ...library.left, state: 'unconfirmed', package: null }
  const catalogue = structuredClone(library.catalogue); catalogue.entries[0].state = 'unconfirmed'
  const h = harness([response(catalogue), response(partial), response(partial)])
  await librarySelection(h, 'r1'); await h.click('compare'); await h.fill('fork-revision', 'r3'); await h.click('fork')
  assert.match(h.el('left-summary').textContent, /Partial or changed build evidence/)
  assert.equal(h.el('revision').value, 'r3'); assert.equal(h.el('build').disabled, true); assert.equal(h.el('export').disabled, true)
})

test('R20 stale close selection and reload responses cannot restore a comparison or replace fields', async () => {
  let release
  const h = harness([response(library.catalogue), () => new Promise((resolve) => { release = resolve }), response(library.right)])
  await librarySelection(h)
  const pending = h.click('compare'); await Promise.resolve(); await Promise.resolve()
  await h.choose('right', 'excavation-haul/r1'); await h.el('close').dispatch('click')
  release(response(library.left)); await pending
  assert.equal(h.el('fork').disabled, true); assert.equal(h.el('diff-loop').textContent, '')
  assert.equal(h.el('save').disabled, false)
})

test('R20 closing delayed fork keeps dirty fields and never writes', async () => {
  let release
  const h = harness([response(library.catalogue), response(library.left), response(library.right), () => new Promise((resolve) => { release = resolve })])
  await h.click('template'); await h.fill('name', 'Keep until fork finishes')
  await librarySelection(h); await h.click('compare'); await h.fill('fork-revision', 'r3')
  const pending = h.click('fork'); await Promise.resolve(); await Promise.resolve()
  await h.el('close').dispatch('click'); release(response(library.left)); await pending
  assert.equal(h.el('name').value, 'Keep until fork finishes'); assert.equal(h.el('save').disabled, false)
  assert.ok(h.requests.every((r) => /\/(catalogue|open)$/.test(r.url)))
})

test('R20 missing selection at inspection or fork keeps editable draft untouched', async () => {
  const h = harness([response(library.catalogue), response(library.left), response(library.right), response({ message: 'Saved draft is missing' }, 409)])
  await h.click('template'); await h.fill('name', 'Unsaved content')
  await librarySelection(h); await h.click('compare'); await h.fill('fork-revision', 'r3'); await h.click('fork')
  assert.match(h.el('status').textContent, /missing/); assert.equal(h.el('name').value, 'Unsaved content')
  assert.equal(h.el('build').disabled, true); assert.equal(h.requests.length, 4)
})

test('R20 stale catalogue digest wrong selection and malformed catalogue fail closed', async () => {
  const stale = structuredClone(library.catalogue); stale.entries[0].design_digest = 'sha256:' + '0'.repeat(64)
  const h = harness([response(stale), response(library.left)])
  await librarySelection(h); await h.click('compare')
  assert.match(h.el('status').textContent, /changed since the library/); assert.equal(h.el('fork').disabled, true)
  const bad = harness([response({ ...library.catalogue, entries: [...library.catalogue.entries, library.catalogue.entries[0]] })])
  await bad.click('catalogue'); assert.match(bad.el('status').textContent, /unsupported/)
  assert.equal(bad.el('compare').disabled, true)
})

test('R20 close suppresses a delayed catalogue and leaves no perpetual loading state', async () => {
  let release
  const h = harness([() => new Promise((resolve) => { release = resolve })])
  await h.click('template'); await h.fill('name', 'Keep draft')
  const pending = h.click('catalogue'); await Promise.resolve(); await Promise.resolve()
  await h.el('close').dispatch('click'); release(response(library.catalogue)); await pending
  assert.match(h.el('library-status').textContent, /interrupted/)
  assert.equal(h.el('name').value, 'Keep draft'); assert.equal(h.el('save').disabled, false)
  assert.equal(h.el('compare').disabled, true)
})

test('R20 saved structured fields compare verbatim and unrepresentable editor copies fail without data loss', async () => {
  const design = JSON.parse(library.right.draft.design_text)
  design.validation.scenarios[0].id = 'id|with-delimiter'
  design.mission.name = '<script>host text</script>'
  const text = JSON.stringify(design), digest = 'sha256:' + createHash('sha256').update(text).digest('hex')
  const view = { ...library.right, draft: { ...library.right.draft, design_text: text, design_digest: digest } }
  const catalogue = structuredClone(library.catalogue); catalogue.entries[1].design_digest = digest; catalogue.entries[1].name = design.mission.name
  const h = harness([response(catalogue), response(library.left), response(view), response(view)])
  await h.click('template'); await h.fill('name', 'Keep exact local content')
  await librarySelection(h); await h.click('compare')
  assert.match(h.el('diff-scenarios').textContent, /id\|with-delimiter/)
  assert.equal(h.root.markup.includes('<script>host text'), false)
  assert.match(h.el('right').children[2].textContent, /<script>host text/)
  await h.choose('fork-source', 'right'); await h.fill('fork-revision', 'r3'); await h.click('fork')
  assert.match(h.el('status').textContent, /cannot round-trip/)
  assert.equal(h.el('name').value, 'Keep exact local content'); assert.equal(h.el('revision').value, 'r1')
})
