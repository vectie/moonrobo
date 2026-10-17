// Local inspection of the native telemetry_plot projection, never raw datasets.
export const PROJECTION_BYTES = 2 * 1024 * 1024
const MAX_INT64 = 9223372036854775807n
function time(value) {
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]{0,18})$/.test(value) || BigInt(value) > MAX_INT64) throw new Error('Recorded milliseconds must be exact nonnegative Int64 strings.')
  return BigInt(value)
}
const integer = value => Number.isSafeInteger(value) && value >= 0
const label = value => typeof value === 'string' && value.trim() && value.length <= 1024 && !/[\u0000-\u0008\u000a-\u001f\ufffe\uffff]/u.test(value)
const escape = value => String(value).replace(/[&<>"']/g, ch => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;' })[ch])

export function inspectTelemetryProjection(text) {
  if (typeof text !== 'string' || new TextEncoder().encode(text).length > PROJECTION_BYTES) throw new Error('Choose a telemetry-plot JSON projection no larger than 2 MiB.')
  let p
  try { p = JSON.parse(text) } catch { throw new Error('Choose valid telemetry-plot JSON, not CSV or a raw recording.') }
  if (p?.format !== 'moonrobo.telemetry-plot.v1' || p.timebase !== 'milliseconds-as-recorded') throw new Error('Expected moonrobo.telemetry-plot.v1 with recorded milliseconds.')
  const start = time(p.start_ms), end = time(p.end_ms), gap = time(p.max_gap_ms)
  if (start > end || gap === 0n || !integer(p.source_sample_count) || !Array.isArray(p.channels) || p.channels.length < 1 || p.channels.length > 16 || !Array.isArray(p.samples) || p.samples.length < 1 || p.samples.length > 10000) throw new Error('Projection exceeds supported bounds (1–16 channels, 1–10000 observations) or has invalid selection metadata.')
  const names = new Set()
  for (const c of p.channels) {
    if (!c || !label(c.channel) || !label(c.unit_label) || names.has(c.channel) || !Number.isFinite(c.minimum) || !Number.isFinite(c.maximum) || c.minimum > c.maximum) throw new Error('Invalid or duplicate channel summary.')
    names.add(c.channel)
  }
  let prior = null, segment = 0
  for (const s of p.samples) {
    if (!s) throw new Error('Invalid observation.')
    const t = time(s.timestamp_ms)
    const connected = prior !== null && t - time(prior.timestamp_ms) <= gap
    if (prior && !connected) segment++
    if (t < start || t > end || (prior && (t <= time(prior.timestamp_ms) || s.source_sample_index !== prior.source_sample_index + 1)) || !integer(s.source_sample_index) || s.source_sample_index >= p.source_sample_count || s.connected !== connected || s.segment !== segment || !Array.isArray(s.values) || s.values.length !== p.channels.length || s.values.some(v => !Number.isFinite(v))) throw new Error('Observation order, source position, connection, segment or values are inconsistent.')
    prior = s
  }
  if (p.segment_count !== segment + 1 || p.gap_count !== segment) throw new Error('Gap summary is inconsistent.')
  p.channels.forEach((c, i) => {
    let min = Infinity, max = -Infinity
    for (const s of p.samples) { min = Math.min(min, s.values[i]); max = Math.max(max, s.values[i]) }
    if (min !== c.minimum || max !== c.maximum) throw new Error('Channel range does not match observations.')
  })
  return p
}

export function selectTelemetryWindow(projection, start, end) {
  const a = time(start), b = time(end)
  if (a > b) throw new Error('Window start must not exceed end.')
  return projection.samples.filter(s => time(s.timestamp_ms) >= a && time(s.timestamp_ms) <= b)
}

export function telemetrySVG(samples, channel, channelIndex, selectedIndex, reference = null) {
  if (!samples.length) return ''
  const first = time(samples[0].timestamp_ms), span = time(samples.at(-1).timestamp_ms) - first
  let min = Infinity, max = -Infinity
  for (const s of samples) { min = Math.min(min, s.values[channelIndex]); max = Math.max(max, s.values[channelIndex]) }
  const scale = Math.max(Math.abs(min), Math.abs(max)) || 1
  const x = s => span === 0n ? 400 : 40 + Number(time(s.timestamp_ms) - first) / Number(span) * 720
  const range = max - min
  const y = s => min === max ? 115 : 190 - (Number.isFinite(range) ? (s.values[channelIndex] - min) / range : (s.values[channelIndex] / scale - min / scale) / (max / scale - min / scale)) * 150
  let shapes = ''
  samples.forEach((s, i) => {
    const previous = samples[i - 1]
    if (previous) shapes += s.connected ? `<line x1="${x(previous)}" y1="${y(previous)}" x2="${x(s)}" y2="${y(s)}" stroke="#44bce8"/>` : `<rect x="${x(previous)}" y="35" width="${x(s) - x(previous)}" height="160" fill="#c98d24" opacity="0.2"><title>Unobserved gap: ${escape((time(s.timestamp_ms) - time(previous.timestamp_ms)).toString())} ms</title></rect>`
    shapes += `<circle cx="${x(s)}" cy="${y(s)}" r="${i === selectedIndex ? 6 : 3}" fill="${i === selectedIndex ? '#ffd166' : '#44bce8'}"><title>${escape(s.timestamp_ms)} ms; value ${s.values[channelIndex]}; source sample ${s.source_sample_index}; segment ${s.segment}</title></circle>`
  })
  const referenceMarker = reference ? `<path d="M ${x(reference)} 30 V 200" stroke="#e98df0" stroke-width="2" stroke-dasharray="8 3"><title>Pinned reference: ${escape(reference.timestamp_ms)} ms</title></path>` : ''
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 800 250" role="img" aria-label="Recorded telemetry plot: ${escape(channel.channel)}"><text x="20" y="20" fill="currentColor">${escape(channel.channel)} (${escape(channel.unit_label)}) · ${min === max ? 'constant' : `${min} to ${max}`}</text>${shapes}${referenceMarker}<path d="M ${x(samples[selectedIndex] || samples[0])} 35 V 195" stroke="#ffd166" stroke-dasharray="4 4"><title>Shared recorded observation cursor</title></path><text x="20" y="222" fill="currentColor">${escape(samples[0].timestamp_ms)} → ${escape(samples.at(-1).timestamp_ms)} ms</text><text x="20" y="244" fill="currentColor">Elapsed span ${span} ms · dots are observations; lines are guides only</text></svg>`
}

export function mountTelemetryReview({ root, dialog, launcher }) {
  if (!root || !dialog || !launcher) return null
  root.innerHTML = `<header><h2 id="telemetry-review-title">Historical telemetry · offline inspection</h2><button id="tr-close" type="button">Close</button></header>
    <p>Open a compact moonrobo.telemetry-plot.v1 JSON exported by telemetry_plot. No raw CSV, live stream, hardware control, upload or evidence acceptance. This is not the trajectory replay protocol.</p>
    <label>Local projection (2 MiB maximum)<input id="tr-file" type="file" accept=".json,application/json"></label>
    <p id="tr-status" role="status" aria-live="polite">Choose a local projection.</p>
    <label>Primary channel<select id="tr-channel"></select></label>
    <label>Compare channel<select id="tr-compare"></select></label>
    <label>Recorded window start (ms)<input id="tr-start" type="text" inputmode="numeric"></label>
    <label>Recorded window end (ms)<input id="tr-end" type="text" inputmode="numeric"></label>
    <button id="tr-window" type="button">Apply window</button><button id="tr-reset" type="button">Full projection</button>
    <div id="tr-plot"></div><p>Amber bands mark unobserved gaps. Each channel uses its own visible range. Both plots share the recorded window and observation cursor; vertical scales and units are independent. No interpolation, correlation or safety conclusion.</p>
    <button id="tr-prev" type="button">Previous observation</button><button id="tr-next" type="button">Next observation</button>
    <label>Observation position<input id="tr-cursor" type="range" min="0" max="0" step="1"></label>
    <label>Exact recorded timestamp (ms)<input id="tr-exact" type="text" inputmode="numeric"></label><button id="tr-seek" type="button">Find exact observation</button>
    <pre id="tr-details"></pre>
    <button id="tr-pin" type="button">Pin current observation as reference</button><button id="tr-unpin" type="button">Clear reference</button>
    <p>Purple dashed line: pinned reference. Gold dashed line: current observation. Measurements are current minus reference; gaps remain unobserved.</p>
    <pre id="tr-measurement" aria-live="polite"></pre>`
  const el = id => root.querySelector(`#tr-${id}`)
  let projection = null, samples = [], cursor = 0, generation = 0, reference = null
  function render() {
    for (const id of ['channel', 'compare', 'start', 'end', 'window', 'reset']) el(id).disabled = !projection
    for (const id of ['cursor', 'exact', 'seek']) el(id).disabled = !samples.length
    el('prev').disabled = !samples.length || cursor === 0
    el('next').disabled = !samples.length || cursor >= samples.length - 1
    el('pin').disabled = !samples.length
    el('unpin').disabled = !reference
    el('cursor').max = String(Math.max(0, samples.length - 1)); el('cursor').value = String(cursor)
    const channel = Number(el('channel').value || 0), s = samples[cursor]
    // The second channel is explicitly chosen, and cannot duplicate the primary.
    if (el('compare').value === String(channel)) el('compare').value = ''
    const compared = el('compare').value
    const channels = compared === '' ? [channel] : [channel, Number(compared)]
    el('compare').disabled = !projection || projection.channels.length < 2
    for (const option of el('compare').children) option.disabled = option.value === String(channel)
    el('plot').innerHTML = s ? channels.map(i => telemetrySVG(samples, projection.channels[i], i, cursor, reference)).join('') : ''
    el('measurement').textContent = s && reference
      ? `Reference timestamp: ${reference.timestamp_ms} ms; source sample ${reference.source_sample_index}\nCurrent timestamp: ${s.timestamp_ms} ms; source sample ${s.source_sample_index}\nSigned elapsed (current − reference): ${time(s.timestamp_ms) - time(reference.timestamp_ms)} ms\nUnobserved gaps crossed: ${Math.abs(s.segment - reference.segment)}\n${channels.map(i => {
        const c = projection.channels[i], delta = s.values[i] - reference.values[i]
        return `${c.channel} (${c.unit_label}): reference ${reference.values[i]}; current ${s.values[i]}; difference ${Number.isFinite(delta) ? String(delta) : 'outside representable range'}`
      }).join('\n')}\nEndpoint differences only. Numeric differences use floating-point arithmetic. No interpolation, rate, correlation or physical conclusion.`
      : 'Pin an observation to measure recorded before/after change.'
    el('details').textContent = s ? `Historical observation ${cursor + 1}/${samples.length}\nRecorded timestamp: ${s.timestamp_ms} ms\nSource sample index: ${s.source_sample_index}\nOriginal segment: ${s.segment}; connected to prior artifact observation: ${s.connected}\n${channels.map(i => `${projection.channels[i].channel}: ${s.values[i]} ${projection.channels[i].unit_label}`).join('\n')}\nSource recording samples: ${projection.source_sample_count}; loaded projection observations: ${projection.samples.length}` : 'No observations in this window.'
    el('exact').value = s?.timestamp_ms || ''
  }
  function clear() { projection = null; samples = []; cursor = 0; reference = null; el('channel').replaceChildren(); el('compare').replaceChildren(); el('compare').value = ''; render() }
  function applyWindow() {
    reference = null
    try { samples = selectTelemetryWindow(projection, el('start').value, el('end').value); cursor = 0; render(); el('status').textContent = samples.length ? `${samples.length} recorded observations in the inclusive window.` : 'No observations in this window. Widen the window or choose Full projection.' }
    catch (error) { samples = []; cursor = 0; render(); el('status').textContent = error.message }
  }
  function reset() { el('start').value = projection.samples[0].timestamp_ms; el('end').value = projection.samples.at(-1).timestamp_ms; applyWindow() }
  el('file').addEventListener('change', async () => {
    const token = ++generation, file = el('file').files?.[0]
    clear()
    if (!file) { el('status').textContent = 'Choose a local projection.'; return }
    el('status').textContent = 'Reading local projection…'
    try {
      if (!Number.isSafeInteger(file.size) || file.size > PROJECTION_BYTES || file.size < 0) throw new Error('Choose a file no larger than 2 MiB.')
      const text = await file.text()
      if (token !== generation) return
      projection = inspectTelemetryProjection(text)
      el('channel').replaceChildren(...projection.channels.map((c, i) => { const option = root.ownerDocument.createElement('option'); option.value = String(i); option.textContent = `${c.channel} (${c.unit_label})`; return option }))
      const none = root.ownerDocument.createElement('option'); none.value = ''; none.textContent = 'None (single channel)'
      el('compare').replaceChildren(none, ...projection.channels.map((c, i) => { const option = root.ownerDocument.createElement('option'); option.value = String(i); option.textContent = `${c.channel} (${c.unit_label})`; return option }))
      el('channel').value = '0'; el('compare').value = ''; reset()
    } catch (error) { if (token !== generation) return; clear(); el('status').textContent = error.message }
  })
  el('window').addEventListener('click', () => { if (projection) applyWindow() })
  el('reset').addEventListener('click', () => { if (projection) reset() })
  el('channel').addEventListener('change', render)
  el('compare').addEventListener('change', render)
  el('pin').addEventListener('click', () => { reference = samples[cursor] || null; render() })
  el('unpin').addEventListener('click', () => { reference = null; render() })
  el('prev').addEventListener('click', () => { cursor = Math.max(0, cursor - 1); render() })
  el('next').addEventListener('click', () => { cursor = Math.min(samples.length - 1, cursor + 1); render() })
  el('cursor').addEventListener('input', () => { cursor = Math.max(0, Math.min(samples.length - 1, Number(el('cursor').value))); render() })
  el('seek').addEventListener('click', () => {
    try { const t = time(el('exact').value), index = samples.findIndex(s => time(s.timestamp_ms) === t); if (index < 0) throw new Error('No exact observation at this timestamp in the current window.'); cursor = index; render(); el('status').textContent = 'Exact recorded observation selected.' }
    catch (error) { el('status').textContent = error.message }
  })
  const cancel = () => { ++generation; el('file').value = ''; clear(); el('status').textContent = 'Choose a local projection.' }
  el('close').addEventListener('click', () => { cancel(); dialog.close() })
  dialog.addEventListener('cancel', cancel); dialog.addEventListener('close', cancel)
  launcher.addEventListener('click', () => { if (!dialog.open) dialog.showModal() })
  render()
}
