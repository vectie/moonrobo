import test from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { createHash, webcrypto } from 'node:crypto'
import { mountDesignWorkbench, parseDesignFields, excavationDraft, inspectSimulationInput, downloadSimulationInput, reuseDesignItems, inspectPortableConcept } from './design-workbench.js'

globalThis.crypto ||= webcrypto
// Actual native producer output, frozen after the focused MoonBit tests. These
// are function/DOM fixtures, not browser, live UI, robot or provider tests.
const built = JSON.parse(await readFile(new URL('../../fixtures/design-workbench-built-view.json', import.meta.url), 'utf8'))
const envelope = JSON.parse(await readFile(new URL('../../fixtures/design-workbench-simulation-input.json', import.meta.url), 'utf8'))
const library = JSON.parse(await readFile(new URL('../../fixtures/design-library-roundtrip.json', import.meta.url), 'utf8'))
const draftView = () => ({ ...structuredClone(built), state: 'draft', package: null })
const response = (payload, status = 200) => ({ ok: status === 200, status, json: async () => payload })
class Element {
  constructor(tag = '') { this.tag = tag; this.listeners = new Map(); this.value = ''; this.disabled = false; this.dataset = {}; this.textContent = ''; this.open = false; this.attributes = new Map() }
  get value() { return this._value }
  set value(value) { this._value = this.tag === 'textarea' ? String(value).replace(/\r\n?/g, '\n') : value }
  addEventListener(event, fn) { this.listeners.set(event, [...(this.listeners.get(event) || []), fn]) }
  async dispatch(event) { if (this.disabled && event === 'click') return; for (const fn of this.listeners.get(event) || []) await fn({ target: this }) }
  setAttribute(name, value) { this.attributes.set(name, value) }
  get selectedOptions() { return (this.children || []).filter(child => child.selected) }
  showModal() { this.open = true }
  close() { this.open = false }
  replaceChildren(...children) { this.children = children; this.value = children[0]?.value || '' }
}
class Root extends Element {
  constructor() { super(); this.ownerDocument = { createElement: tag => new Element(tag) } }
  set innerHTML(text) { this.markup = text; this.elements = new Map([...text.matchAll(/<([a-z]+)\b[^>]*\bid="([^"]+)"/g)].map(([, tag, id]) => [id, new Element(tag)])) }
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

const mr = (h, id) => h.root.querySelector(`#mr-${id}`)
const practice = (h, id) => mr(h, id).dispatch('click')

test('R578 actual workbench loads edited loop and practices without host or bridge calls', async () => {
  const h = harness()
  await practice(h, 'load'); assert.match(mr(h, 'status').textContent, /design ID/)
  await h.click('template'); await h.fill('steps', 'Dig\nLoad\nHaul\nDump')
  await practice(h, 'load'); assert.equal(mr(h, 'steps').children.length, 4)
  assert.match(mr(h, 'steps').children[0].textContent, /Current: Dig/)
  await practice(h, 'start'); await practice(h, 'start')
  for (let i = 0; i < 4; i++) await practice(h, 'next')
  assert.match(mr(h, 'status').textContent, /completed.*4\/4.*no mission outcome was validated/)
  assert.equal(mr(h, 'next').disabled, true); assert.equal(mr(h, 'start').disabled, true)
  await practice(h, 'reset'); assert.equal(mr(h, 'progress').value, 0)
  assert.equal(h.requests.length, 0); assert.equal(h.downloads.length, 0)
  assert.match(h.root.markup, /manual digital tabletop exercise/)
})

test('R578 workbench close Escape and edit cannot silently continue rehearsal', async () => {
  const h = harness()
  await h.click('template'); await practice(h, 'load'); await practice(h, 'start'); await practice(h, 'next')
  await h.click('close'); assert.match(mr(h, 'status').textContent, /held.*1\/4/)
  await h.launcher.dispatch('click'); assert.equal(mr(h, 'next').disabled, true)
  await practice(h, 'start'); await h.dialog.dispatch('cancel')
  assert.match(mr(h, 'status').textContent, /held.*1\/4/)
  await practice(h, 'start'); await h.fill('max', '0.2')
  assert.equal(mr(h, 'next').disabled, true); assert.equal(mr(h, 'start').disabled, true)
  assert.equal(mr(h, 'steps').children.length, 0)
  await practice(h, 'load'); assert.match(mr(h, 'status').textContent, /ready.*0\/4/)
  await h.click('template'); assert.equal(mr(h, 'start').disabled, true)
  assert.equal(h.requests.length, 0)
})

test('R578 visible interlocks preserve unknown step across repeated recovery clicks', async () => {
  const h = harness()
  await h.click('template'); await practice(h, 'load'); await practice(h, 'start'); await practice(h, 'gap')
  await practice(h, 'hazard'); await practice(h, 'restore'); await practice(h, 'restore')
  assert.equal(mr(h, 'start').disabled, true); assert.match(mr(h, 'status').textContent, /UNKNOWN/)
  await practice(h, 'done'); await practice(h, 'done')
  assert.equal(mr(h, 'progress').value, 1); assert.equal(mr(h, 'start').disabled, true)
  await practice(h, 'clear'); assert.match(mr(h, 'status').textContent, /held/)
  await practice(h, 'start'); await practice(h, 'next'); assert.equal(mr(h, 'progress').value, 2)
  assert.equal(h.requests.length, 0)
})

test('R578 invalid visible speed cannot start and task text never becomes markup', async () => {
  const h = harness()
  await h.click('template'); await h.fill('steps', '<img src=x onerror=alert(1)>\nLoad\nHaul\nDump'); await practice(h, 'load')
  assert.match(mr(h, 'steps').children[0].textContent, /<img/)
  assert.equal(h.root.markup.includes('<img src'), false)
  mr(h, 'speed').value = '9'; await mr(h, 'speed').dispatch('input')
  assert.equal(mr(h, 'start').disabled, true)
  // A parent refresh must still not allow the visible invalid speed to run.
  await h.choose('fork-source', 'left'); await practice(h, 'start')
  assert.match(mr(h, 'status').textContent, /within/); assert.equal(mr(h, 'next').disabled, true)
  mr(h, 'speed').value = '0.1'; await mr(h, 'speed').dispatch('input'); await practice(h, 'start')
  assert.match(mr(h, 'status').textContent, /running/)
})

test('R578 new workbench instance clears practice and delayed host work blocks practice controls', async () => {
  let release
  const h = harness([() => new Promise((resolve) => { release = resolve })])
  await h.click('template'); await practice(h, 'load')
  const pending = h.click('save'); await Promise.resolve(); await Promise.resolve()
  assert.equal(mr(h, 'start').disabled, true); await practice(h, 'start')
  release(response(draftView())); await pending
  assert.equal(mr(h, 'start').disabled, true)
  const fresh = harness(); assert.equal(mr(fresh, 'steps').children.length, 0)
  assert.equal(mr(fresh, 'start').disabled, true)
})

const conceptFields = (design) => ({ id:design.design_id,revision:design.revision,name:design.mission.name,steps:design.task_loop.join('\n'),mechanisms:design.mechanisms.map(m=>`${m.id} | ${m.kind}`).join('\n'),scenarios:design.validation.scenarios.map(s=>`${s.id} | ${s.expected}`).join('\n'),min:String(design.constraints.commanded_speed_mps.min),max:String(design.constraints.commanded_speed_mps.max) })
const currentConcept = () => {
 const design=excavationDraft();design.design_id='current-site';design.revision='r7';design.mission.name='Current editable site';design.task_loop[0]='Keep my bounded task';design.constraints.commanded_speed_mps.max=0.15
 design.mechanisms.forEach(item=>item.id='current-'+item.id);design.validation.scenarios.forEach(item=>item.id='current-'+item.id);return design
}
const selectedItems = {mechanisms:['excavator'],scenarios:['nominal-cycle']}
const fieldSnapshot = h => Object.fromEntries(Object.keys(conceptFields(excavationDraft())).map(id=>[id,h.el(id).value]))
const setConcept = async(h,design=currentConcept()) => {for(const [id,value] of Object.entries(conceptFields(design)))await h.fill(id,value)}
async function pickItems(h, mechanisms=['excavator'], scenarios=['nominal-cycle']) {
 for(const [key,ids] of [['mechanisms',mechanisms],['scenarios',scenarios]]) {h.el('reuse-'+key).children.forEach(option=>option.selected=ids.includes(option.value));await h.el('reuse-'+key).dispatch('change')}
}
async function prepareReuse(h) {await setConcept(h);await librarySelection(h);await h.click('compare');await h.choose('reuse-source','right');await h.choose('reuse-group','both');await pickItems(h)}
function syntheticDraftResponse(design) {const text=JSON.stringify(design);return {draft:{contract_id:'moonrobo.design-draft.v1',design_id:design.design_id,revision:design.revision,design_text:text,design_digest:'sha256:'+createHash('sha256').update(text).digest('hex'),recorded_at:'2026-10-12T15:00:00Z'},state:'draft',package:null,physical_execution_allowed:false}}

test('R594 selected declaration merge retains current identity loop speed and untouched items without mutating either source',()=>{
 const current=currentConcept(),source=JSON.parse(library.right.draft.design_text),before=structuredClone({current,source});const merged=reuseDesignItems(current,source,selectedItems)
 assert.deepEqual({current,source},before);assert.equal(merged.design_id,'current-site');assert.equal(merged.revision,'r7');assert.deepEqual(merged.mission,current.mission);assert.deepEqual(merged.task_loop,current.task_loop);assert.deepEqual(merged.constraints,current.constraints)
 assert.deepEqual(merged.mechanisms,[...current.mechanisms,source.mechanisms[0]]);assert.deepEqual(merged.validation.scenarios,[...current.validation.scenarios,source.validation.scenarios[0]]);assert.equal(merged.mission.authority,'digital-only')
 const selectedOnly=structuredClone(source);selectedOnly.task_loop[0]='Unselected\nmultiline step';assert.deepEqual(reuseDesignItems(current,selectedOnly,selectedItems),merged)
})
test('R594 exact and changed ID conflicts, duplicate or missing selections and limit overflow reject atomically',()=>{
 const current=currentConcept(),source=excavationDraft(),before=structuredClone(current)
 for(const selection of [null,{}, {mechanisms:[],scenarios:[]},{mechanisms:['excavator','excavator'],scenarios:[]},{mechanisms:['missing'],scenarios:[]},{...selectedItems,extra:true}])assert.throws(()=>reuseDesignItems(current,source,selection))
 for(const conflict of ['mechanisms','scenarios']){const draft=structuredClone(current);if(conflict==='mechanisms')draft.mechanisms.push(source.mechanisms[0]);else draft.validation.scenarios.push(source.validation.scenarios[0]);assert.throws(()=>reuseDesignItems(draft,source,selectedItems),/Conflicting/)}
 for(const group of ['mechanisms','scenarios']){const draft=structuredClone(current),items=group==='mechanisms'?draft.mechanisms:draft.validation.scenarios;for(let i=items.length;i<11;i++)items.push(group==='mechanisms'?{id:'extra-'+i,kind:'bounded'}:{id:'extra-'+i,expected:'bounded'});assert.equal((group==='mechanisms'?reuseDesignItems(draft,source,selectedItems).mechanisms:reuseDesignItems(draft,source,selectedItems).validation.scenarios).length,12);items.push(group==='mechanisms'?{id:'last',kind:'bounded'}:{id:'last',expected:'bounded'});assert.throws(()=>reuseDesignItems(draft,source,selectedItems),/12-item limit/)}
 for(const change of [d=>d.mechanisms[0].kind='two\nlines',d=>d.validation.scenarios[0].id='pipe | id',d=>d.validation.scenarios[0].expected=' trailing ']){const draft=structuredClone(source);change(draft);assert.throws(()=>reuseDesignItems(current,draft,selectedItems),/round-trip|mechanisms|scenarios|pair per line/)}
 assert.throws(()=>reuseDesignItems(current,{...source,mission:{...source.mission,authority:'physical'}},selectedItems),/digital-only/);assert.deepEqual(current,before)
})
test('R594 production controller previews complete combined fields then re-reads source before selective apply and explicit save',async()=>{
 const source=JSON.parse(library.right.draft.design_text),combined=reuseDesignItems(currentConcept(),source,selectedItems)
 // Source inspection uses retained actual native producer output. The new save
 // response below is an explicitly synthetic host fixture, not a native build.
 const h=harness([response(library.catalogue),response(library.left),response(library.right),response(library.right),response(syntheticDraftResponse(combined))])
 await prepareReuse(h);const before=fieldSnapshot(h),requests=h.requests.length;await h.click('reuse-preview');assert.deepEqual(fieldSnapshot(h),before);assert.equal(h.requests.length,requests)
 const preview=JSON.parse(h.el('reuse-result').textContent);assert.deepEqual(preview.combined_design,combined);assert.deepEqual(preview.selected_items,selectedItems);assert.equal(preview.source_digest,library.right.draft.design_digest);assert.equal(h.el('reuse-apply').disabled,false)
 await h.click('reuse-apply');assert.deepEqual(fieldSnapshot(h),conceptFields(combined));assert.deepEqual(h.requests.at(-1).parsed,{design_id:'excavation-haul',revision:'r2'});assert.ok(h.requests.every(r=>/\/(catalogue|open)$/.test(r.url)));assert.equal(h.el('reuse-apply').disabled,true);assert.equal(h.el('build').disabled,true);assert.equal(h.el('export').disabled,true);assert.equal(h.downloads.length,0)
 assert.match(h.el('reuse-status').textContent,/no build or hardware action/);await h.click('reuse-apply');assert.equal(h.requests.length,requests+1)
 await h.click('save');assert.deepEqual(h.requests.at(-1).parsed.design,combined);assert.equal(h.el('build').disabled,false);assert.equal(h.el('export').disabled,true)
})
test('R594 source groups restrict additions and visible conflicts retain current editable fields',async()=>{
 const h=harness([response(library.catalogue),response(library.left),response(library.right),response(library.right)])
 await prepareReuse(h);await h.choose('reuse-group','mechanisms');assert.equal(h.el('reuse-scenarios').disabled,true);await h.click('reuse-preview');const preview=JSON.parse(h.el('reuse-result').textContent);assert.deepEqual(preview.selected_items,{mechanisms:['excavator'],scenarios:[]});await h.click('reuse-apply');assert.equal(h.el('scenarios').value,conceptFields(currentConcept()).scenarios)
 const before=fieldSnapshot(h);await h.click('reuse-preview');assert.match(h.el('reuse-status').textContent,/Conflicting mechanisms ID excavator/);assert.equal(h.el('reuse-apply').disabled,true);assert.deepEqual(fieldSnapshot(h),before)
 await h.choose('reuse-group','scenarios');await h.click('reuse-preview');assert.equal(JSON.parse(h.el('reuse-result').textContent).combined_design.validation.scenarios.length,4)
 await pickItems(h,[],[]);await h.click('reuse-preview');assert.match(h.el('reuse-status').textContent,/at least one/);assert.equal(h.el('reuse-apply').disabled,true)
})
test('R594 preview invalidates after editor, source, group, item, close, Escape and library changes',async()=>{
 const h=harness([response(library.catalogue),response(library.left),response(library.right),response(library.catalogue)])
 await prepareReuse(h);await h.click('reuse-preview');await h.fill('name','Changed current name');assert.equal(h.el('reuse-apply').disabled,true);assert.equal(h.el('reuse-result').textContent,'')
 await h.click('reuse-preview');await h.choose('reuse-group','mechanisms');assert.equal(h.el('reuse-apply').disabled,true)
 await h.click('reuse-preview');await pickItems(h,['mobility'],[]);assert.equal(h.el('reuse-apply').disabled,true)
 await h.click('reuse-preview');await h.choose('reuse-source','left');assert.equal(h.el('reuse-apply').disabled,true);assert.equal(h.el('reuse-mechanisms').selectedOptions.length,0)
 await pickItems(h);await h.click('reuse-preview');await h.click('close');assert.equal(h.el('reuse-apply').disabled,true)
 await h.click('reuse-preview');await h.dialog.dispatch('cancel');assert.equal(h.el('reuse-apply').disabled,true)
 await h.click('reuse-preview');await h.click('catalogue');assert.equal(h.el('reuse-preview').disabled,true);assert.equal(h.el('reuse-apply').disabled,true);assert.equal(h.el('reuse-result').textContent,'');assert.equal(h.el('name').value,'Changed current name')
})
test('R594 stale changed source and unreadable re-read fail without replacing fields or writing',async()=>{
 for(const failure of ['changed','missing']){
  const changed=JSON.parse(library.right.draft.design_text);changed.mechanisms[0].kind='changed after inspection';const view=syntheticDraftResponse(changed)
  const h=harness([response(library.catalogue),response(library.left),response(library.right),failure==='changed'?response(view):response({message:'Missing saved source'},409)])
  await prepareReuse(h);await h.click('reuse-preview');const before=fieldSnapshot(h);await h.click('reuse-apply');assert.deepEqual(fieldSnapshot(h),before);assert.equal(h.el('reuse-apply').disabled,true);assert.match(h.el('reuse-status').textContent,/Reuse not applied/);assert.match(h.el('status').textContent,/changed since|Missing saved/);assert.ok(h.requests.every(r=>/\/(catalogue|open)$/.test(r.url)))
 }
})
test('R594 delayed apply is single-flight and close newer source or newer editor suppresses stale copy',async()=>{
 for(const interrupt of ['close','source','editor']){
  let release;const h=harness([response(library.catalogue),response(library.left),response(library.right),()=>new Promise(resolve=>release=resolve)])
  await prepareReuse(h);await h.click('reuse-preview');const before=fieldSnapshot(h);const pending=h.click('reuse-apply');while(!release)await new Promise(resolve=>setImmediate(resolve));const count=h.requests.length;await h.el('reuse-apply').dispatch('click');assert.equal(h.requests.length,count)
  if(interrupt==='close')await h.el('close').dispatch('click');else if(interrupt==='source')await h.choose('reuse-source','left');else await h.fill('name','Newer target')
  release(response(library.right));await pending;assert.deepEqual(fieldSnapshot(h),interrupt==='editor'?{...before,name:'Newer target'}:before);assert.equal(h.el('reuse-apply').disabled,true);assert.equal(h.el('export').disabled,true);assert.equal(h.downloads.length,0)
 }
})
test('R594 unconfirmed source permits selected declarations only and never copies old build readiness',async()=>{
 const partial={...library.right,state:'unconfirmed',package:null};const h=harness([response(library.catalogue),response(library.left),response(partial),response(partial)])
 await prepareReuse(h);await h.click('reuse-preview');await h.click('reuse-apply');assert.equal(h.el('build').disabled,true);assert.equal(h.el('export').disabled,true);assert.equal(h.el('save').disabled,false);assert.equal(h.el('id').value,'current-site');assert.equal(h.el('revision').value,'r7')
})
test('R594 apply checks target field bytes again even if a programmatic change omitted its input event',async()=>{
 let release;const h=harness([response(library.catalogue),response(library.left),response(library.right),()=>new Promise(resolve=>release=resolve)])
 await prepareReuse(h);await h.click('reuse-preview');const before=fieldSnapshot(h);const pending=h.click('reuse-apply');while(!release)await new Promise(resolve=>setImmediate(resolve));h.el('name').value='Changed without an event';release(response(library.right));await pending
 assert.deepEqual(fieldSnapshot(h),{...before,name:'Changed without an event'});assert.match(h.el('reuse-status').textContent,/Reuse not applied: Source selection or editable fields changed/);assert.equal(h.el('reuse-apply').disabled,true)
})
test('R594 item labels and combined preview render source declarations strictly as text',async()=>{
 const source=JSON.parse(library.right.draft.design_text);source.mechanisms[0].kind='<img src=x onerror=alert(1)> bounded scoop';const view=syntheticDraftResponse(source),catalogue=structuredClone(library.catalogue);catalogue.entries[1].design_digest=view.draft.design_digest
 const h=harness([response(catalogue),response(library.left),response(view),response(view)]);await prepareReuse(h);assert.equal(h.el('reuse-mechanisms').children[0].textContent,'excavator | '+source.mechanisms[0].kind);await h.click('reuse-preview');assert.match(h.el('reuse-result').textContent,/<img src=x/);assert.doesNotMatch(h.root.markup,/<img src=x/);await h.click('reuse-apply');assert.ok(h.el('mechanisms').value.includes(source.mechanisms[0].kind));assert.ok(h.requests.every(r=>/\/(catalogue|open)$/.test(r.url)))
})


// R608 reads the unchanged native export fixture. Altered exports and host save
// responses below are explicit synthetic negatives/mocks, not new native runs.
const portableText = () => JSON.stringify(envelope)
const rehashPacket = packet => { const package_json = JSON.stringify(packet); return JSON.stringify({ contract_id: envelope.contract_id, package_json, package_digest: 'sha256:' + createHash('sha256').update(package_json).digest('hex') }) }
const alteredPortable = mutate => {
  const packet = JSON.parse(envelope.package_json), source = packet.sources.find(item => item.artifact_ref === packet.design_ref), design = JSON.parse(source.text)
  mutate(design, packet)
  source.text = JSON.stringify(design); source.digest = 'sha256:' + createHash('sha256').update(source.text).digest('hex')
  return rehashPacket(packet)
}
const fileFor = (text = portableText(), name = 'from-other-workspace.json') => ({ name, size: Buffer.byteLength(text), text: async () => text })
async function choosePortable(h, file = fileFor()) { h.el('portable-file').files = file ? [file] : []; await h.el('portable-file').dispatch('change') }
async function portablePreview(h, text = portableText(), id = 'local-rover', revision = 'r8') {
  await choosePortable(h, fileFor(text)); await h.click('portable-inspect'); await h.fill('portable-id', id); await h.fill('portable-revision', revision); await h.click('portable-preview')
}

test('R608 native exported envelope exposes only digest-bound editable design and source identity', async () => {
  const source = await inspectPortableConcept(portableText())
  assert.deepEqual(source.design, excavationDraft())
  assert.deepEqual(Object.keys(source).sort(), ['design', 'source'])
  assert.deepEqual(source.source, { design_id: 'excavation-haul', revision: 'r1', design_ref: 'books/excavation-haul/r1/design/robot-design.json', design_digest: built.draft.design_digest, package_digest: envelope.package_digest, verified_sources: JSON.parse(envelope.package_json).sources.map(({ artifact_ref, digest }) => ({ artifact_ref, digest })) })
  assert.doesNotMatch(JSON.stringify(source), /robobook_ready|validation_status|physical_ready|run-receipt/)
})

test('R608 tampered envelope and every source digest are rejected before preview', async () => {
  await assert.rejects(inspectPortableConcept(JSON.stringify({ ...envelope, package_json: envelope.package_json + ' ' })), /digest/)
  for (let i = 0; i < 8; i++) {
    const packet = JSON.parse(envelope.package_json); packet.sources[i].text += ' altered'
    await assert.rejects(inspectPortableConcept(rehashPacket(packet)), /digest mismatch/)
  }
  for (const change of [p => p.design_ref = 'elsewhere', p => p.robot_artifact.robot_json_sha256 = '0'.repeat(64), p => p.sources.pop(), p => p.sources[1] = p.sources[0], p => p.physical_execution_allowed = true, p => p.review_required = false]) {
    const packet = JSON.parse(envelope.package_json); change(packet); await assert.rejects(inspectPortableConcept(rehashPacket(packet)))
  }
})

test('R608 self-consistently rehashed embedded identity class and authority mismatches reject', async () => {
  for (const change of [d => d.design_id = 'other', d => d.revision = 'other', d => d.contract_id = 'other', d => d.mission.authority = 'physical', d => d.mission.robot_class = 'other']) await assert.rejects(inspectPortableConcept(alteredPortable(change)), /embedded design/)
  for (const value of ['../escape', '', 'UPPER', 'x'.repeat(65), null]) {
    const packet = JSON.parse(envelope.package_json); packet.design_id = value
    await assert.rejects(inspectPortableConcept(rehashPacket(packet)), /lowercase slugs/)
  }
})

test('R608 unknown design fields, stripped values and unsupported editor round-trips fail closed', async () => {
  for (const change of [d => d.geometry = { secret: 'unsupported' }, d => d.mission.calibration = 'foreign', d => d.mechanisms[0].length = 4, d => d.validation.scenarios[0].receipt = 'accepted', d => d.validation.accepted = true, d => d.constraints.acceleration = 1, d => d.constraints.commanded_speed_mps.units = 'm/s', d => d.mission.name = ' spaced ', d => d.mission.name = 'two\nlines', d => d.mission.name = '', d => d.task_loop[0] += '\nextra step', d => d.mechanisms[0].kind = ' trimmed ', d => d.validation.scenarios[0].id = 'pipe | id', d => d.constraints.commanded_speed_mps.max = 0.9, d => d.task_loop = [], d => d.mechanisms[0].kind = 7, d => d.mission.name = null]) {
    await assert.rejects(inspectPortableConcept(alteredPortable(change)), /losslessly editable/)
  }
  // Object member order is not semantic loss; task and declaration order is.
  const reordered = alteredPortable(d => { d.mission = { robot_class: d.mission.robot_class, name: d.mission.name, authority: d.mission.authority } })
  assert.deepEqual((await inspectPortableConcept(reordered)).design, excavationDraft())
})

test('R608 production file controls inspect and preview locally then replace into ordinary separate save', async () => {
  const local = { ...excavationDraft(), design_id: 'local-rover', revision: 'r8' }
  const h = harness([response(syntheticDraftResponse(local))]); await setConcept(h)
  const before = fieldSnapshot(h); await portablePreview(h)
  assert.deepEqual(fieldSnapshot(h), before); assert.equal(h.requests.length, 0); assert.equal(h.downloads.length, 0)
  assert.deepEqual(JSON.parse(h.el('portable-source').textContent).editable_design, excavationDraft())
  const verifiedSources = JSON.parse(envelope.package_json).sources.map(({ artifact_ref, digest }) => ({ artifact_ref, digest }))
  assert.equal(verifiedSources.length, 8)
  assert.deepEqual(JSON.parse(h.el('portable-source').textContent).source.verified_sources, verifiedSources)
  assert.deepEqual(JSON.parse(h.el('portable-result').textContent).source.verified_sources, verifiedSources)
  assert.deepEqual(JSON.parse(h.el('portable-result').textContent).replacement_design, local)
  assert.match(h.root.markup, /type="file" accept=".json,application\/json"/)
  assert.match(h.el('portable-status').textContent, /Preview only/)
  await h.click('portable-apply'); assert.deepEqual(fieldSnapshot(h), conceptFields(local))
  assert.equal(h.el('portable-apply').disabled, true); assert.equal(h.el('build').disabled, true); assert.equal(h.el('export').disabled, true)
  assert.equal(h.requests.length, 0); assert.equal(h.downloads.length, 0); assert.match(h.el('portable-status').textContent, /validation acceptance was not transferred/)
  await h.click('portable-apply'); assert.equal(h.requests.length, 0)
  await h.click('save'); assert.equal(h.requests.length, 1); assert.match(h.requests[0].url, /\/save$/); assert.deepEqual(h.requests[0].parsed.design, local)
  assert.equal(h.el('build').disabled, false); assert.equal(h.el('export').disabled, true)
  assert.doesNotMatch(JSON.stringify(h.requests[0].parsed), /package_json|robobook_ready|validation_status/)
})

test('R608 replacement preserves unsaved work on cancellation and consumes its preview', async () => {
  let confirmations = 0
  const h = harness([], () => { confirmations++; return false }); await setConcept(h); const before = fieldSnapshot(h)
  await portablePreview(h); assert.equal(confirmations, 0); await h.click('portable-apply')
  assert.equal(confirmations, 1); assert.deepEqual(fieldSnapshot(h), before); assert.equal(h.el('portable-apply').disabled, true); assert.match(h.el('portable-status').textContent, /canceled/); assert.equal(h.requests.length, 0)
})

test('R608 source tuple and known local revisions reject while a changed ID or revision permits preview', async () => {
  const h = harness([response(library.catalogue)]); await portablePreview(h, portableText(), 'excavation-haul', 'r1')
  assert.equal(h.el('portable-apply').disabled, true); assert.match(h.el('portable-status').textContent, /different from/)
  await h.fill('portable-revision', 'r2'); await h.click('portable-preview'); assert.equal(h.el('portable-apply').disabled, false)
  await h.click('catalogue'); assert.equal(h.el('portable-apply').disabled, true); await h.click('portable-preview'); assert.match(h.el('portable-status').textContent, /already known/)
  await h.fill('portable-id', 'local-site'); await h.fill('portable-revision', 'r1'); await h.click('portable-preview'); assert.equal(h.el('portable-apply').disabled, false)
  for (const value of ['', '../bad', 'BAD', 'x'.repeat(65)]) { await h.fill('portable-id', value); await h.click('portable-preview'); assert.equal(h.el('portable-apply').disabled, true) }
  const savedDesign = { ...excavationDraft(), design_id: 'saved-local', revision: 'r7' }
  const saved = harness([response(syntheticDraftResponse(savedDesign))]); await saved.fill('id', 'saved-local'); await saved.fill('revision', 'r7'); await saved.click('open'); await portablePreview(saved, portableText(), 'saved-local', 'r7'); assert.equal(saved.el('portable-apply').disabled, true); assert.match(saved.el('portable-status').textContent, /already known/)
})

test('R608 applied concept invalidates prior local build and rehearsal without inheriting export readiness', async () => {
  const h = harness([response(built)]); await select(h); await h.click('open'); assert.equal(h.el('export').disabled, false)
  await portablePreview(h); assert.equal(h.el('export').disabled, false)
  await h.click('portable-apply'); assert.equal(h.el('export').disabled, true); assert.equal(h.el('build').disabled, true); assert.equal(mr(h, 'start').disabled, true)
  assert.match(h.el('state').textContent, /Unsaved/); assert.match(h.el('export-status').textContent, /No export/); assert.equal(h.requests.length, 1)
})

test('R608 file, target, editor, close and Escape changes invalidate portable previews', async () => {
  for (const interrupt of ['file', 'identity', 'editor', 'close', 'escape']) {
    const h = harness(); await setConcept(h); await portablePreview(h)
    if (interrupt === 'file') await choosePortable(h)
    if (interrupt === 'identity') await h.fill('portable-id', 'newer')
    if (interrupt === 'editor') await h.fill('name', 'Keep newer draft')
    if (interrupt === 'close') await h.click('close')
    if (interrupt === 'escape') await h.dialog.dispatch('cancel')
    assert.equal(h.el('portable-apply').disabled, true); assert.equal(h.el('portable-result').textContent, ''); assert.equal(h.requests.length, 0)
    assert.equal(h.el('name').value, interrupt === 'editor' ? 'Keep newer draft' : currentConcept().mission.name)
  }
})

test('R608 apply rechecks exact editor bytes and identity even without input events', async () => {
  for (const target of ['name', 'portable-id', 'portable-file']) {
    const h = harness(); await setConcept(h); await portablePreview(h)
    if (target === 'portable-file') h.el(target).files = [fileFor()]
    else h.el(target).value += ' '
    const before = fieldSnapshot(h); await h.click('portable-apply')
    if (target === 'portable-id') {
      // Identity controls use their trimmed slug; adding whitespace preserves it.
      assert.equal(h.el('id').value, 'local-rover')
    } else { assert.deepEqual(fieldSnapshot(h), before); assert.match(h.el('portable-status').textContent, /changed/); assert.equal(h.el('portable-apply').disabled, true) }
    assert.equal(h.requests.length, 0)
  }
  const h = harness(); await portablePreview(h); h.el('portable-revision').value = 'newer'; await h.click('portable-apply'); assert.match(h.el('portable-status').textContent, /changed/)
  h.el('portable-file').files = [fileFor()]; await h.click('portable-preview'); assert.equal(h.el('portable-apply').disabled, true); assert.match(h.el('portable-status').textContent, /selected file changed/)
})

test('R608 local file reading is single-flight and interrupted callbacks cannot replace newer state', async () => {
  for (const interrupt of ['close', 'escape', 'file', 'editor', 'identity']) {
    let release, reads = 0
    const h = harness(); await setConcept(h)
    const file = { size: Buffer.byteLength(portableText()), text: () => { reads++; return new Promise(resolve => release = resolve) } }
    await choosePortable(h, file); const pending = h.click('portable-inspect'); while (!release) await new Promise(resolve => setImmediate(resolve))
    assert.equal(h.el('portable-file').disabled, true); await h.el('portable-inspect').dispatch('click'); assert.equal(reads, 1)
    if (interrupt === 'close') await h.el('close').dispatch('click')
    if (interrupt === 'escape') await h.dialog.dispatch('cancel')
    if (interrupt === 'file') await choosePortable(h)
    if (interrupt === 'editor') await h.fill('name', 'Newer draft')
    if (interrupt === 'identity') await h.fill('portable-id', 'newer')
    release(portableText()); await pending
    assert.equal(h.el('portable-source').textContent, ''); assert.equal(h.el('portable-preview').disabled, true); assert.equal(h.el('portable-apply').disabled, true); assert.equal(h.requests.length, 0)
    assert.equal(h.el('name').value, interrupt === 'editor' ? 'Newer draft' : currentConcept().mission.name)
  }
})

test('R608 invalid, unreadable and oversized files clear prior import without altering editor', async () => {
  const h = harness(); await setConcept(h); const before = fieldSnapshot(h)
  for (const file of [fileFor('{broken'), fileFor('{}'), fileFor('null'), { size: 2 * 1024 * 1024 + 1, text: () => { throw Error('must not read oversized file') } }, { size: 1, text: async () => { throw Error('File access failed') } }, fileFor('')]) {
    await portablePreview(h); await choosePortable(h, file); await h.click('portable-inspect')
    assert.equal(h.el('portable-preview').disabled, true); assert.equal(h.el('portable-apply').disabled, true); assert.equal(h.el('portable-source').textContent, ''); assert.deepEqual(fieldSnapshot(h), before); assert.equal(h.requests.length, 0)
    assert.match(h.el('portable-status').textContent, /rejected/); assert.doesNotMatch(h.el('portable-status').textContent, /must not read/)
  }
  await assert.rejects(inspectPortableConcept('é'.repeat(1024 * 1024 + 1)), /2 MiB/)
  await choosePortable(h, null); assert.equal(h.el('portable-inspect').disabled, true)
})

test('R608 local immutable-save conflict is visible and never silently renames or retries', async () => {
  const h = harness([response({ message: 'Revision already exists' }, 409)]); await portablePreview(h); await h.click('portable-apply'); const before = fieldSnapshot(h)
  await h.click('save'); assert.equal(h.requests.length, 1); assert.deepEqual(fieldSnapshot(h), before); assert.match(h.el('status').textContent, /already exists.*no retry/)
  assert.equal(h.el('save').disabled, true); assert.equal(h.el('build').disabled, true); assert.equal(h.el('export').disabled, true)
  await h.click('save'); assert.equal(h.requests.length, 1)
  await portablePreview(h); assert.equal(h.el('portable-apply').disabled, true); assert.match(h.el('portable-status').textContent, /unconfirmed/)
})

test('R608 portable names and concept text remain text while reload starts without imported state', async () => {
  const text = alteredPortable(d => { d.mission.name = '<img src=x onerror=alert(1)>'; d.mechanisms[0].kind = '<script>no execution</script>' })
  const h = harness(); await portablePreview(h, text); assert.match(h.el('portable-source').textContent, /<img src=x/); assert.match(h.el('portable-result').textContent, /<script>/); assert.doesNotMatch(h.root.markup, /<img src=x|<script>/)
  await h.click('portable-apply'); assert.equal(h.el('name').value, '<img src=x onerror=alert(1)>'); assert.equal(h.requests.length, 0)
  const fresh = harness(); assert.equal(fresh.el('portable-source').textContent, ''); assert.equal(fresh.el('portable-preview').disabled, true); assert.equal(fresh.el('portable-apply').disabled, true)
})


test('R608 textarea CR and CRLF normalization cannot silently alter portable declarations', async () => {
  const h = harness(); await setConcept(h); const before = fieldSnapshot(h)
  const control = new Element('textarea'); control.value = 'First\rsecond\r\nthird'; assert.equal(control.value, 'First\nsecond\nthird')
  for (const newline of ['\r', '\r\n']) {
    for (const change of [d => d.task_loop[0] = `First${newline}second`, d => d.mechanisms[0].kind = `scoop${newline}second`, d => d.validation.scenarios[0].expected = `safe${newline}second`, d => d.validation.scenarios[0].id = `scenario${newline}second`]) {
      const text = alteredPortable(change)
      await assert.rejects(inspectPortableConcept(text), /losslessly editable/)
      await choosePortable(h, fileFor(text)); await h.click('portable-inspect')
      assert.deepEqual(fieldSnapshot(h), before); assert.equal(h.el('portable-preview').disabled, true); assert.equal(h.el('portable-apply').disabled, true); assert.equal(h.requests.length, 0)
    }
  }
})
