import test from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { inspectTelemetryProjection as inspect, selectTelemetryWindow, telemetrySVG, mountTelemetryReview, PROJECTION_BYTES } from './telemetry-review.js'
const fixtureText = await readFile(new URL('../../fixtures/cockpit-telemetry-plot.json', import.meta.url), 'utf8')
const fixture = () => JSON.parse(fixtureText)
// Mounted production handlers with a small DOM double, not graphical browser QA.
class Element {
  constructor() { this.children = []; this.listeners = new Map(); this.value = ''; this.disabled = false; this.textContent = ''; this.open = false }
  addEventListener(type, handler) { this.listeners.set(type, [...this.listeners.get(type) || [], handler]) }
  async dispatch(type) { if (this.disabled && type === 'click') return; for (const handler of this.listeners.get(type) || []) await handler({ target: this }) }
  replaceChildren(...children) { this.children = children }
  showModal() { this.open = true }
  close() { this.open = false }
}
class Root extends Element {
  constructor() { super(); this.ownerDocument = { createElement: () => new Element() } }
  set innerHTML(value) { this.markup = value; this.elements = new Map([...value.matchAll(/id="([^"]+)"/g)].map(([, id]) => [id, new Element()])) }
  querySelector(selector) { const element = this.elements.get(selector.slice(1)); assert.ok(element, selector); return element }
}
function harness() {
  const root = new Root(), dialog = new Element(), launcher = new Element()
  mountTelemetryReview({ root, dialog, launcher })
  const el = id => root.querySelector(`#tr-${id}`)
  const load = async (text = fixtureText) => { el('file').files = [{ size: new TextEncoder().encode(text).length, text: async () => text }]; await el('file').dispatch('change') }
  return { root, dialog, launcher, el, load, click: id => el(id).dispatch('click') }
}
test('pinned reference measures exact signed elapsed time and both channel endpoints through mounted controls', async () => {
  const h = harness(); assert.equal(h.el('pin').disabled, true)
  await h.load(); await h.click('pin')
  assert.match(h.el('measurement').textContent, /Signed elapsed \(current − reference\): 0 ms/)
  assert.match(h.el('measurement').textContent, /difference 0/)
  await h.click('next')
  assert.match(h.el('measurement').textContent, /Reference timestamp: 9007199254740993/)
  assert.match(h.el('measurement').textContent, /Signed elapsed \(current − reference\): 100 ms/)
  assert.match(h.el('measurement').textContent, /motor.current.a \(A\): reference 1.2; current 1.8; difference 0.6000000000000001/)
  h.el('compare').value = '1'; await h.el('compare').dispatch('change')
  assert.match(h.el('measurement').textContent, /temperature.c \(°C\): reference 22; current 22.5; difference 0.5/)
  assert.equal((h.el('plot').innerHTML.match(/Pinned reference: 9007199254740993/g) || []).length, 2)
  assert.equal((h.el('plot').innerHTML.match(/Shared recorded observation cursor/g) || []).length, 2)
  await h.click('pin'); await h.click('prev')
  assert.match(h.el('measurement').textContent, /Signed elapsed \(current − reference\): -100 ms/)
  assert.match(h.el('measurement').textContent, /reference 22.5; current 22; difference -0.5/)
  h.el('channel').value = '1'; await h.el('channel').dispatch('change')
  assert.match(h.el('measurement').textContent, /Reference timestamp: 9007199254741093/)
  assert.equal((h.el('plot').innerHTML.match(/Pinned reference:/g) || []).length, 1)
  await h.click('unpin'); assert.doesNotMatch(h.el('plot').innerHTML, /Pinned reference:/)
  assert.equal(h.el('unpin').disabled, true)
})
test('reference measurements count gaps in both directions without fabricating missing observations', async () => {
  const h = harness(); await h.load(); await h.click('pin')
  h.el('exact').value = '9007199254742993'; await h.click('seek')
  assert.match(h.el('measurement').textContent, /Signed elapsed \(current − reference\): 2000 ms/)
  assert.match(h.el('measurement').textContent, /Unobserved gaps crossed: 1/)
  const measurement = h.el('measurement').textContent
  h.el('exact').value = '9007199254742992'; await h.click('seek')
  assert.equal(h.el('measurement').textContent, measurement)
  await h.click('pin'); h.el('cursor').value = '0'; await h.el('cursor').dispatch('input')
  assert.match(h.el('measurement').textContent, /Signed elapsed \(current − reference\): -2000 ms/)
  assert.match(h.el('measurement').textContent, /Unobserved gaps crossed: 1/)
  assert.match(h.el('measurement').textContent, /Endpoint differences only/)
})
test('reference resets on windows, invalid windows, file changes, close and Escape', async () => {
  for (const action of [h => h.click('window'), h => h.click('reset'), h => h.load(), h => h.load('invalid'), h => h.click('close'), h => h.dialog.dispatch('cancel'), h => h.dialog.dispatch('close'), async h => {
    h.el('start').value = '9'; h.el('end').value = '2'; await h.click('window')
  }, async h => {
    h.el('start').value = '1'; h.el('end').value = '2'; await h.click('window')
    assert.equal(h.el('pin').disabled, true)
  }]) {
    const h = harness(); await h.load(); await h.click('pin'); await action(h)
    assert.equal(h.el('unpin').disabled, true)
    assert.doesNotMatch(h.el('plot').innerHTML, /Pinned reference:/)
    assert.match(h.el('measurement').textContent, /Pin an observation/)
  }
})
test('measurement preserves Int64 extremes and reports numeric difference overflow honestly', async () => {
  const p = fixture(); p.samples = p.samples.slice(0, 2)
  p.samples[0].timestamp_ms = '0'; p.samples[1].timestamp_ms = '9223372036854775807'
  p.samples[1].connected = false; p.samples[1].segment = 1
  p.samples[0].values = [-Number.MAX_VALUE, 5]; p.samples[1].values = [Number.MAX_VALUE, 5]
  p.channels[0].minimum = -Number.MAX_VALUE; p.channels[0].maximum = Number.MAX_VALUE
  p.channels[1].minimum = 5; p.channels[1].maximum = 5
  const h = harness(); await h.load(JSON.stringify(p)); await h.click('pin'); await h.click('next')
  assert.match(h.el('measurement').textContent, /9223372036854775807 ms/)
  assert.match(h.el('measurement').textContent, /difference outside representable range/)
  assert.doesNotMatch(h.el('measurement').textContent, /Infinity|NaN/)
  await h.click('pin'); await h.click('prev')
  assert.match(h.el('measurement').textContent, /-9223372036854775807 ms/)
  h.el('channel').value = '1'; await h.el('channel').dispatch('change')
  assert.match(h.el('measurement').textContent, /reference 5; current 5; difference 0/)
})
test('actual native CLI projection enters mounted loader, selects channels and exact observations', async () => {
  const h = harness(); assert.equal(h.el('next').disabled, true)
  await h.launcher.dispatch('click'); assert.equal(h.dialog.open, true)
  await h.load(); assert.match(h.el('details').textContent, /9007199254740993/)
  await h.click('next'); assert.match(h.el('details').textContent, /9007199254741093/)
  await h.click('prev'); assert.match(h.el('details').textContent, /9007199254740993/)
  h.el('channel').value = '1'; await h.el('channel').dispatch('change'); assert.match(h.el('details').textContent, /temperature.c: 22 °C/)
  h.el('exact').value = '9007199254742993'; await h.click('seek'); assert.equal(h.el('cursor').value, '4')
  h.el('exact').value = '9007199254742994'; await h.click('seek'); assert.match(h.el('status').textContent, /No exact/); assert.equal(h.el('cursor').value, '4')
  h.el('cursor').value = '5'; await h.el('cursor').dispatch('input'); assert.equal(h.el('next').disabled, true)
})
test('mounted inclusive windows, empty window, invalid window and full projection recovery', async () => {
  const h = harness(); await h.load()
  h.el('start').value = '9007199254741093'; h.el('end').value = '9007199254741493'; await h.click('window')
  assert.match(h.el('status').textContent, /3 recorded/); assert.match(h.el('details').textContent, /Source sample index: 1/)
  h.el('start').value = '9007199254741494'; h.el('end').value = '9007199254742992'; await h.click('window')
  assert.equal(h.el('plot').innerHTML, ''); assert.equal(h.el('seek').disabled, true); assert.match(h.el('status').textContent, /No observations/)
  h.el('start').value = '9'; h.el('end').value = '2'; await h.click('window'); assert.match(h.el('status').textContent, /must not exceed/)
  await h.click('reset'); assert.match(h.el('status').textContent, /6 recorded/)
})
test('gaps disconnected, one point/constants centered, precise nearby timestamps and extremes finite', () => {
  const p = inspect(fixtureText), svg = telemetrySVG(p.samples, p.channels[0], 0, 0)
  assert.equal((svg.match(/<line /g) || []).length, 4); assert.equal((svg.match(/<rect /g) || []).length, 1)
  assert.match(svg, /1500 ms/); assert.match(svg, /9007199254740993/)
  const samples = [{ ...p.samples[0], values: [Number.MAX_VALUE] }, { ...p.samples[1], timestamp_ms: '9007199254740994', values: [-Number.MAX_VALUE] }]
  const extreme = telemetrySVG(samples, p.channels[0], 0, 0)
  assert.doesNotMatch(extreme, /NaN|Infinity/); assert.match(extreme, /cx="760"/)
  const single = telemetrySVG(samples.slice(0, 1), p.channels[0], 0, 0)
  assert.match(single, /constant/); assert.match(single, /cx="400" cy="115"/)
  assert.equal(selectTelemetryWindow(p, p.samples[0].timestamp_ms, p.samples[0].timestamp_ms).length, 1)
})
test('projection validation rejects malformed formats, timestamps, counts, order, topology and summaries', () => {
  for (const mutate of [p => p.format = 'moonrobo.replay.v1', p => p.samples[0].timestamp_ms = 9007199254740992, p => p.start_ms = '-1', p => p.end_ms = '9223372036854775808', p => p.max_gap_ms = '0', p => p.samples[1].timestamp_ms = p.samples[0].timestamp_ms, p => p.samples[1].connected = false, p => p.samples[4].segment = 0, p => p.gap_count = 0, p => p.source_sample_count = 5, p => p.samples[2].source_sample_index = 9, p => p.channels[0].maximum = 4, p => p.channels[1].channel = p.channels[0].channel, p => p.samples[0].values.pop(), p => p.samples = [], p => p.channels[0].unit_label = '\n']) {
    const p = fixture(); mutate(p); assert.throws(() => inspect(JSON.stringify(p)))
  }
  assert.throws(() => inspect('timestamp_ms,value\n1,2')); assert.throws(() => inspect(' '.repeat(PROJECTION_BYTES + 1)))
})
test('hostile channel and unit labels remain text or escaped SVG markup', async () => {
  const p = fixture(); p.channels[0].channel = '<img onerror="evil()">&&'; p.channels[0].unit_label = '</text><script>evil()</script>'
  const h = harness(); await h.load(JSON.stringify(p))
  assert.equal(h.el('channel').children[0].textContent, `${p.channels[0].channel} (${p.channels[0].unit_label})`)
  assert.doesNotMatch(h.el('plot').innerHTML, /<script>|<img/); assert.match(h.el('plot').innerHTML, /&lt;img/)
  assert.match(h.el('details').textContent, /<img/); assert.doesNotMatch(h.root.markup, /evil/)
})
test('new selection supersedes stale success and stale failure; oversized reads never start', async () => {
  const h = harness(); let release
  h.el('file').files = [{ size: 100, text: () => new Promise(resolve => { release = resolve }) }]
  const pending = h.el('file').dispatch('change'); await h.load(); await h.click('next'); release(fixtureText); await pending
  assert.equal(h.el('cursor').value, '1')
  let reject
  h.el('file').files = [{ size: 100, text: () => new Promise((_, fail) => { reject = fail }) }]
  const failing = h.el('file').dispatch('change'); await h.load(); reject(new Error('old failure')); await failing
  assert.match(h.el('status').textContent, /6 recorded/)
  h.el('file').files = [{ size: PROJECTION_BYTES + 1, text: () => { throw new Error('must not read') } }]; await h.el('file').dispatch('change')
  assert.match(h.el('status').textContent, /no larger than/); assert.equal(h.el('next').disabled, true)
})
test('close and Escape invalidate pending reads and clear historical selections', async () => {
  for (const close of [h => h.click('close'), h => h.dialog.dispatch('cancel'), h => h.dialog.dispatch('close')]) {
    const h = harness(); let release
    h.el('file').files = [{ size: 100, text: () => new Promise(resolve => { release = resolve }) }]
    const pending = h.el('file').dispatch('change'); await close(h); release(fixtureText); await pending
    assert.equal(h.el('next').disabled, true); assert.equal(h.el('plot').innerHTML, '')
  }
})
test('production entrypoint mounts review and module has no network or hardware path', async () => {
  const html = await readFile(new URL('./index.html', import.meta.url), 'utf8'), bootstrap = await readFile(new URL('./bootstrap.js', import.meta.url), 'utf8'), source = await readFile(new URL('./telemetry-review.js', import.meta.url), 'utf8')
  assert.match(html, /id="telemetry-review-open"/); assert.match(bootstrap, /mountTelemetryReview\(\{/)
  assert.doesNotMatch(source, /\bfetch\s*\(|XMLHttpRequest|WebSocket|\/api\//)
})
test('explicit paired channels share exact cursor, gaps and inclusive window with independent units', async () => {
  const h = harness(); await h.load()
  assert.equal(h.el('compare').value, '')
  assert.equal((h.el('plot').innerHTML.match(/<svg /g) || []).length, 1)
  h.el('compare').value = '1'; await h.el('compare').dispatch('change')
  const plots = () => h.el('plot').innerHTML.match(/<svg .*?<\/svg>/g)
  assert.equal(plots().length, 2)
  assert.match(plots()[0], /motor.current.a \(A\)/); assert.match(plots()[1], /temperature.c \(°C\)/)
  assert.match(h.el('details').textContent, /motor.current.a: 1.2 A\ntemperature.c: 22 °C/)
  for (const plot of plots()) { assert.equal((plot.match(/<rect /g) || []).length, 1); assert.match(plot, /1500 ms/) }
  h.el('exact').value = '9007199254742993'; await h.click('seek')
  assert.match(h.el('details').textContent, /motor.current.a: 1.1 A\ntemperature.c: 23.2 °C/)
  assert.equal(plots()[0].match(/<path d="([^"]+)/)[1], plots()[1].match(/<path d="([^"]+)/)[1])
  assert.match(h.el('details').textContent, /Original segment: 1; connected to prior artifact observation: false/)
  h.el('exact').value = '9007199254742000'; await h.click('seek')
  assert.match(h.el('status').textContent, /No exact/); assert.equal(h.el('cursor').value, '4')
  h.el('start').value = '9007199254741093'; h.el('end').value = '9007199254741493'; await h.click('window')
  for (const plot of plots()) { assert.match(plot, /9007199254741093 → 9007199254741493/); assert.equal((plot.match(/<circle /g) || []).length, 3); assert.doesNotMatch(plot, /<rect /) }
  await h.click('next'); assert.match(h.el('details').textContent, /motor.current.a: 3.2 A\ntemperature.c: 23 °C/)
  h.el('start').value = '9007199254741494'; h.el('end').value = '9007199254742992'; await h.click('window')
  assert.equal(h.el('plot').innerHTML, ''); assert.equal(h.el('next').disabled, true)
  await h.click('reset'); assert.equal(plots().length, 2)
})
test('channel switching removes duplicate comparison, and one-channel or replacement files reset it', async () => {
  const h = harness(); await h.load()
  h.el('compare').value = '1'; await h.el('compare').dispatch('change')
  h.el('channel').value = '1'; await h.el('channel').dispatch('change')
  assert.equal(h.el('compare').value, ''); assert.equal(h.el('compare').children[2].disabled, true)
  h.el('compare').value = '0'; await h.el('compare').dispatch('change')
  assert.match(h.el('details').textContent, /temperature.c: 22 °C\nmotor.current.a: 1.2 A/)
  await h.load(); assert.equal(h.el('compare').value, '')
  const p = fixture(); p.channels.pop(); p.samples.forEach(s => s.values.pop())
  await h.load(JSON.stringify(p)); assert.equal(h.el('compare').disabled, true)
  assert.equal((h.el('plot').innerHTML.match(/<svg /g) || []).length, 1)
  await h.click('close'); assert.equal(h.el('compare').children.length, 0)
})
test('production stylesheet stacks full-width plots and keeps narrow-screen scrolling', async () => {
  const css = await readFile(new URL('./styles.css', import.meta.url), 'utf8')
  assert.match(css, /#tr-plot svg \{ display: block; width: 100%; height: auto; min-width: 600px; \}/)
  assert.match(css, /#tr-plot svg \+ svg \{ margin-top: 1rem; \}/)
  assert.match(css, /#tr-plot \{ overflow-x: auto; \}/)
})
