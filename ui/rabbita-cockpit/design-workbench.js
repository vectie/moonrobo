// Digital artifact authoring only. No gateway, bridge, SDK or provider route.
const API = '/api/moonrobo/design-workbench/'
const SLUG = /^[a-z0-9_-]{1,64}$/

export function compareDesigns(left, right) {
  const rows = []
  const row = (group, label, a, b) => rows.push({ group, label, left: a ?? '(absent)', right: b ?? '(absent)', changed: a !== b })
  for (let i = 0; i < Math.max(left.task_loop.length, right.task_loop.length); i++) row('Task loop', `Step ${i + 1}`, left.task_loop[i], right.task_loop[i])
  for (const [group, a, b, field] of [['Mechanisms', left.mechanisms, right.mechanisms, 'kind'], ['Scenarios', left.validation.scenarios, right.validation.scenarios, 'expected']]) {
    const ids = [...new Set([...a, ...b].map((item) => item.id))].sort()
    for (const id of ids) row(group, id, a.find((item) => item.id === id)?.[field], b.find((item) => item.id === id)?.[field])
  }
  for (const limit of ['min', 'max']) row('Speed (m/s)', limit, left.constraints.commanded_speed_mps[limit], right.constraints.commanded_speed_mps[limit])
  return rows
}

function designFields(design) {
  return {
    id: design.design_id, revision: design.revision, name: design.mission.name || design.design_id,
    steps: design.task_loop.join('\n'), mechanisms: design.mechanisms.map((m) => `${m.id} | ${m.kind}`).join('\n'),
    scenarios: design.validation.scenarios.map((s) => `${s.id} | ${s.expected}`).join('\n'),
    min: String(design.constraints.commanded_speed_mps.min), max: String(design.constraints.commanded_speed_mps.max),
  }
}

async function verifyView(view, id, revision) {
  if (!view?.draft || view.draft.contract_id !== 'moonrobo.design-draft.v1' || view.draft.design_id !== id || view.draft.revision !== revision || view.physical_execution_allowed !== false || !['draft', 'built', 'unconfirmed'].includes(view.state)) throw new Error('The host returned a different or unsupported design revision.')
  if (await digest(view.draft.design_text) !== view.draft.design_digest) throw new Error('The saved draft digest did not match its exact text.')
  const design = JSON.parse(view.draft.design_text)
  if (design.contract_id !== 'moonsuite.robot-design.v1' || design.design_id !== id || design.revision !== revision || design.mission?.authority !== 'digital-only' || design.mission?.robot_class !== 'excavation-haul-rover') throw new Error('The saved design identity or class is unsupported.')
  const { task_loop: steps, mechanisms, validation, constraints } = design
  const scenarios = validation?.scenarios, speed = constraints?.commanded_speed_mps
  const nonempty = (value) => typeof value === 'string' && value.trim().length > 0
  if (!Array.isArray(steps) || steps.length < 4 || steps.length > 24 || !steps.every(nonempty) || !Array.isArray(mechanisms) || mechanisms.length < 3 || mechanisms.length > 12 || mechanisms.some((item) => typeof item?.id !== 'string' || !SLUG.test(item.id) || !nonempty(item?.kind)) || new Set(mechanisms.map((item) => item.id)).size !== mechanisms.length || !Array.isArray(scenarios) || scenarios.length < 3 || scenarios.length > 12 || scenarios.some((item) => !nonempty(item?.id) || !nonempty(item?.expected)) || new Set(scenarios.map((item) => item.id)).size !== scenarios.length || !Number.isFinite(speed?.min) || !Number.isFinite(speed?.max) || speed.min <= 0 || speed.max < speed.min || speed.max > 0.5) throw new Error('Saved design fields are incomplete or outside workbench bounds.')
  const packet = view.state === 'built' ? await inspectSimulationInput(view.package, id, revision) : null
  if (packet && packet.sources.find((source) => source.artifact_ref === packet.design_ref)?.text !== view.draft.design_text) throw new Error('The built package design does not match the saved draft.')
  return { design, packet }
}

export function excavationDraft() {
  return {
    contract_id: 'moonsuite.robot-design.v1', design_id: 'excavation-haul', revision: 'r1',
    mission: { name: 'Excavation and haul concept', authority: 'digital-only', robot_class: 'excavation-haul-rover' },
    task_loop: ['Excavate a bounded scoop', 'Load the payload bed', 'Haul to the delivery area', 'Dump and return to safe hold'],
    mechanisms: [{ id: 'excavator', kind: 'scoop' }, { id: 'payload-bed', kind: 'tipping-bed' }, { id: 'mobility', kind: 'wheeled' }],
    validation: { scenarios: [{ id: 'nominal-cycle', expected: 'Delivery completes within declared bounds' }, { id: 'hazard-stop', expected: 'Motion stops when the hazard is detected' }, { id: 'low-energy-return', expected: 'The declared energy reserve is preserved' }] },
    constraints: { commanded_speed_mps: { min: 0.01, max: 0.1 } },
  }
}

export function parseDesignFields(values) {
  const lines = (text) => text.split('\n').map((line) => line.trim()).filter(Boolean)
  const pairs = (text, second) => lines(text).map((line) => {
    const split = line.indexOf('|')
    if (split < 1 || !line.slice(split + 1).trim()) throw new Error(`Use one ID | ${second} pair per line.`)
    return { id: line.slice(0, split).trim(), [second]: line.slice(split + 1).trim() }
  })
  if (!SLUG.test(values.id) || !SLUG.test(values.revision)) throw new Error('Use lowercase letters, numbers, hyphens or underscores for the design ID and revision (1–64 characters).')
  const steps = lines(values.steps), mechanisms = pairs(values.mechanisms, 'kind'), scenarios = pairs(values.scenarios, 'expected')
  if (steps.length < 4 || steps.length > 24) throw new Error('Enter 4–24 task-loop steps, one per line.')
  if (mechanisms.length < 3 || mechanisms.length > 12 || mechanisms.some((m) => !SLUG.test(m.id)) || new Set(mechanisms.map((m) => m.id)).size !== mechanisms.length) throw new Error('Enter 3–12 mechanisms with unique lowercase IDs.')
  if (scenarios.length < 3 || scenarios.length > 12 || new Set(scenarios.map((s) => s.id)).size !== scenarios.length) throw new Error('Enter 3–12 scenarios with unique IDs and expected outcomes.')
  const min = Number(values.min), max = Number(values.max)
  if (!Number.isFinite(min) || !Number.isFinite(max) || min <= 0 || max < min || max > 0.5) throw new Error('Speed limits require 0 < minimum ≤ maximum ≤ 0.5 m/s.')
  return {
    contract_id: 'moonsuite.robot-design.v1', design_id: values.id, revision: values.revision,
    mission: { name: values.name.trim() || values.id, authority: 'digital-only', robot_class: 'excavation-haul-rover' },
    task_loop: steps, mechanisms, validation: { scenarios }, constraints: { commanded_speed_mps: { min, max } },
  }
}

async function digest(text, crypto = globalThis.crypto) {
  const bytes = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text))
  return 'sha256:' + [...new Uint8Array(bytes)].map((byte) => byte.toString(16).padStart(2, '0')).join('')
}

export async function inspectSimulationInput(envelope, id, revision) {
  if (envelope?.contract_id !== 'moonrobo.simulation-input-envelope.v1' || typeof envelope.package_json !== 'string' || await digest(envelope.package_json) !== envelope.package_digest) throw new Error('The simulation-input package digest could not be verified.')
  const packet = JSON.parse(envelope.package_json)
  if (packet.contract_id !== 'moonrobo.simulation-input.v1' || packet.design_id !== id || packet.revision !== revision || packet.physical_execution_allowed !== false || packet.review_required !== true) throw new Error('The simulation-input package identity or authority is wrong.')
  const root = `books/${id}/${revision}`
  const files = ['robot.json', 'model/robot.urdf', 'bridge/bridge.json', 'safety/policy.json', 'design/robot-design.json', 'design/build-receipt.json', 'design/validation-receipt.json', 'design/integration-receipt.json']
  if (!Array.isArray(packet.sources) || packet.sources.length !== files.length || new Set(packet.sources.map((s) => s.artifact_ref)).size !== files.length) throw new Error('The package source list is incomplete or duplicated.')
  for (const file of files) {
    const source = packet.sources.find((item) => item.artifact_ref === `${root}/${file}`)
    if (!source || typeof source.text !== 'string' || source.digest !== await digest(source.text)) throw new Error(`Source digest mismatch: ${file}`)
  }
  const binding = packet.robot_artifact
  if (!binding || binding.robot_id !== id || binding.robot_revision !== revision || binding.artifact_root !== root || binding.physical_transport_enabled !== false || binding.validation_status !== 'accepted') throw new Error('The robot artifact binding is wrong.')
  for (const [path, hash, file] of [['robot_json_path', 'robot_json_sha256', 'robot.json'], ['robot_urdf_path', 'robot_urdf_sha256', 'model/robot.urdf'], ['validation_receipt_path', 'validation_receipt_sha256', 'design/validation-receipt.json']]) {
    if (binding[path] !== file || binding[hash] !== packet.sources.find((s) => s.artifact_ref === `${root}/${file}`).digest.slice(7)) throw new Error(`Robot source binding mismatch: ${file}`)
  }
  if (binding.bridge_config_path !== 'bridge/bridge.json' || packet.design_ref !== `${root}/design/robot-design.json` || packet.integration_receipt_ref !== `${root}/design/integration-receipt.json`) throw new Error('Package references do not match the selected revision.')
  return packet
}

export function downloadSimulationInput(envelope, id, revision, document = globalThis.document, url = globalThis.URL) {
  const href = url.createObjectURL(new Blob([JSON.stringify(envelope, null, 2) + '\n'], { type: 'application/json' }))
  const link = document.createElement('a')
  link.href = href
  link.download = `moonrobo-${id.replace(/[^a-z0-9_-]/g, '_')}-${revision.replace(/[^a-z0-9_-]/g, '_')}-simulation-input.json`
  document.body.appendChild(link)
  try { link.click() } finally { link.remove(); url.revokeObjectURL(href) }
}

const PANEL = `
  <header class="digital-trials-heading"><div><p class="eyebrow">MoonRobo · digital design</p><h2 id="design-workbench-title">Build a robot concept</h2></div><button id="dw-close" type="button">Close</button></header>
  <p class="digital-trials-boundary">Excavation-haul rover only · simulation-only bridge · physical authority: <strong>false</strong></p>
  <p id="dw-status" role="status" aria-live="polite">Start a draft, or browse your saved design library.</p>
  <section class="design-library" aria-labelledby="dw-library-title">
    <h3 id="dw-library-title">Saved design library</h3>
    <button id="dw-catalogue" type="button">Refresh saved designs</button>
    <p id="dw-library-status" role="status">Refresh to discover saved revisions. Browsing and comparing are read-only.</p>
    <pre id="dw-library-issues" aria-label="Saved revision warnings"></pre>
    <div class="design-workbench-grid">
      <div><label for="dw-left">Revision A</label><select id="dw-left"><option value="">Choose a saved revision</option></select><pre id="dw-left-summary">No revision inspected</pre></div>
      <div><label for="dw-right">Revision B</label><select id="dw-right"><option value="">Choose a saved revision</option></select><pre id="dw-right-summary">No revision inspected</pre></div>
    </div>
    <button id="dw-compare" type="button">Inspect and compare selected revisions</button>
    <p id="dw-comparison-status" role="status">Choose two revisions. Comparing a revision with itself is allowed.</p>
    <div class="design-workbench-grid">
      <div><h4>Task loop</h4><pre id="dw-diff-loop"></pre><h4>Mechanisms</h4><pre id="dw-diff-mechanisms"></pre></div>
      <div><h4>Validation scenarios</h4><pre id="dw-diff-scenarios"></pre><h4>Speed limits (m/s)</h4><pre id="dw-diff-speed"></pre></div>
    </div>
    <label for="dw-fork-source">Fork inspected revision</label><select id="dw-fork-source"><option value="left">Revision A</option><option value="right">Revision B</option></select>
    <label for="dw-fork-revision">New revision name</label><input id="dw-fork-revision" autocomplete="off" placeholder="r2" />
    <button id="dw-fork" type="button">Fork into editable fields</button>
    <p>Forking only fills the editor below. Save, build and download are separate actions. Originals stay immutable.</p>
  </section>
  <div class="design-workbench-grid">
    <section><h3>1. Describe the digital robot</h3><button id="dw-template" type="button">Start excavation-haul draft</button>
      <label for="dw-id">Design ID</label><input id="dw-id" autocomplete="off" placeholder="south-site-hauler" />
      <label for="dw-revision">Revision</label><input id="dw-revision" autocomplete="off" placeholder="r1" />
      <label for="dw-name">Display name</label><input id="dw-name" />
      <button id="dw-open" type="button">Re-open saved revision</button>
      <label for="dw-steps">Task loop · 4–24 steps, one per line</label><textarea id="dw-steps" rows="5"></textarea>
      <label for="dw-mechanisms">Mechanisms · 3–12 lines: ID | kind</label><textarea id="dw-mechanisms" rows="4" spellcheck="false"></textarea>
      <label for="dw-scenarios">Validation scenarios · 3–12 lines: ID | expected outcome</label><textarea id="dw-scenarios" rows="5"></textarea>
      <div class="design-speed"><div><label for="dw-min">Minimum speed (m/s)</label><input id="dw-min" type="number" min="0.001" max="0.5" step="0.01" /></div><div><label for="dw-max">Maximum speed (m/s)</label><input id="dw-max" type="number" min="0.001" max="0.5" step="0.01" /></div></div>
      <p>Changes need a new revision. Saved drafts and builds are immutable; earlier revisions stay available.</p>
      <button id="dw-save" type="button">Save draft revision</button>
    </section>
    <section><h3>2. Build and inspect</h3><p id="dw-state">No saved revision selected</p><button id="dw-build" type="button">Build this digital revision</button>
      <p>The existing builder produces a robot profile, generic box-link URDF, simulation bridge, deny-by-default physical safety policy, build receipt and artifact validation receipt.</p>
      <p class="digital-trials-warning">This is a bounded concept builder. It does not create manufacturing CAD or calibrated dynamics. Validation checks artifact consistency; it does not run your mission scenarios.</p>
      <pre id="dw-preview" tabindex="0" aria-label="Saved design and generated artifact summary">No build yet.</pre>
      <h3>3. Continue in MoonMoon</h3><button id="dw-export" type="button">Download simulation-input package</button>
      <p id="dw-export-status">Build a saved revision first. MoonMoon still needs site, terrain, mission criteria and calibration evidence before simulation.</p>
      <p>Your editable fields survive closing this panel. Refresh the library after a page reload. Downloads contain exact source text and SHA256 bindings; downloading does not run a simulation.</p>
    </section>
  </div>`

export function mountDesignWorkbench({ root, dialog, launcher, hostUrl = '', fetchImpl = (...args) => globalThis.fetch(...args), now = () => new Date().toISOString(), download = downloadSimulationInput, confirmReplace = (text) => globalThis.confirm?.(text) === true } = {}) {
  if (!root || !dialog || !launcher) return null
  root.innerHTML = PANEL
  const el = (id) => root.querySelector(`#dw-${id}`)
  const fieldIds = ['id', 'revision', 'name', 'steps', 'mechanisms', 'scenarios', 'min', 'max']
  const fields = Object.fromEntries(fieldIds.map((id) => [id, el(id)]))
  const actionIds = ['template', 'open', 'save', 'build', 'export', 'catalogue', 'compare', 'fork']
  let saved = null, busy = false, busyMutation = false, generation = 0, lastTask = Promise.resolve(), dirty = true
  let entries = [], inspected = null
  const libraryKey = (entry) => `${entry.design_id}/${entry.revision}`
  const entryFor = (side) => entries.find((entry) => libraryKey(entry) === el(side).value && entry.selectable)
  const clearComparison = () => {
    inspected = null
    for (const id of ['left-summary', 'right-summary', 'diff-loop', 'diff-mechanisms', 'diff-scenarios', 'diff-speed']) el(id).textContent = ''
    el('comparison-status').textContent = 'Choose revisions, then inspect and compare.'
  }
  const permitReplace = () => !dirty || !['name', 'steps', 'mechanisms', 'scenarios', 'min', 'max'].some((id) => fields[id].value !== '') || confirmReplace('Replace your unsaved editable fields? Cancel to keep them. No saved revision will be changed.')
  const uncertain = new Set()
  const key = () => `${fields.id.value.trim()}/${fields.revision.value.trim()}`
  const message = (text, error = false) => { el('status').textContent = text; el('status').dataset.error = String(error) }
  const current = () => saved && saved.draft.design_id === fields.id.value.trim() && saved.draft.revision === fields.revision.value.trim() && !dirty && !uncertain.has(key())
  const update = () => {
    for (const id of actionIds) el(id).disabled = busy
    for (const input of Object.values(fields)) input.disabled = busy
    el('save').disabled = busy || uncertain.has(key())
    el('build').disabled = busy || !current() || saved.state !== 'draft'
    el('export').disabled = busy || !current() || saved.state !== 'built'
    el('compare').disabled = busy || !entryFor('left') || !entryFor('right')
    el('fork').disabled = busy || !inspected || !inspected[el('fork-source').value || 'left']
    for (const id of ['left', 'right', 'fork-source', 'fork-revision']) el(id).disabled = busy
    root.setAttribute('aria-busy', String(busy))
  }
  const populate = (design) => {
    const values = designFields(design), roundtrip = parseDesignFields(values)
    const pairs = (items, field) => items.map((item) => [item.id, item[field]])
    if (JSON.stringify(roundtrip.task_loop) !== JSON.stringify(design.task_loop) || JSON.stringify(pairs(roundtrip.mechanisms, 'kind')) !== JSON.stringify(pairs(design.mechanisms, 'kind')) || JSON.stringify(pairs(roundtrip.validation.scenarios, 'expected')) !== JSON.stringify(pairs(design.validation.scenarios, 'expected'))) throw new Error('This saved design contains fields that cannot round-trip through the line-based editor. Its source has been kept unchanged.')
    for (const [id, value] of Object.entries(values)) fields[id].value = value
  }
  const invalidate = () => { saved = null; dirty = true; el('state').textContent = 'Unsaved or unconfirmed selection'; el('preview').textContent = 'Re-open or save this draft before building.'; el('export-status').textContent = 'No export for this selection.' }
  const display = async (view, id, revision, token) => {
    const { design, packet } = await verifyView(view, id, revision)
    if (token !== generation) return false
    populate(design); saved = view; dirty = false; uncertain.delete(`${id}/${revision}`)
    if (view.state === 'unconfirmed') uncertain.add(`${id}/${revision}`)
    el('state').textContent = `${id} / ${revision} · ${view.state === 'built' ? 'artifact validation passed' : view.state} · digital-only`
    el('preview').textContent = JSON.stringify(packet ? { design, generated_sources: packet.sources.map(({ artifact_ref, digest }) => ({ artifact_ref, digest })), robot_artifact: packet.robot_artifact, limitations: packet.limitations } : design, null, 2)
    el('export-status').textContent = packet ? 'Ready to export robot inputs. No mission simulation or physical readiness has been established.' : 'Build a saved revision before exporting.'
    if (view.state === 'unconfirmed') message(view.message || 'Build outcome unconfirmed. Preserve this revision and use a new revision after review.', true)
    return true
  }
  const request = async (operation, body) => {
    const response = await fetchImpl(hostUrl.replace(/\/$/, '') + API + operation, { method: 'POST', headers: { Accept: 'application/json', 'Content-Type': 'application/json' }, cache: 'no-store', body: JSON.stringify(body) })
    const payload = await response.json()
    if (!response.ok) throw new Error(payload?.message || payload?.error?.message || `Host rejected the request (HTTP ${response.status}).`)
    return payload
  }
  const run = (action, mutation = false) => {
    if (busy) return lastTask
    busy = true; busyMutation = mutation; const token = ++generation; update()
    lastTask = Promise.resolve().then(() => action(token)).catch((error) => { if (token === generation) message(error.message || 'Request failed; your editable draft was kept.', true) }).finally(() => { busy = false; update() })
    return lastTask
  }
  const selected = () => {
    const id = fields.id.value.trim(), revision = fields.revision.value.trim()
    if (!SLUG.test(id) || !SLUG.test(revision)) throw new Error('Enter the design ID and revision as lowercase slugs first.')
    return { id, revision }
  }
  launcher.addEventListener('click', () => { if (!dialog.open) dialog.showModal() })
  const cancelRequest = () => {
    ++generation
    if (busy && busyMutation) { uncertain.add(key()); invalidate() }
    if (busy && !busyMutation) {
      message('Read-only request interrupted. Your editable fields were kept.')
      if (el('library-status').textContent === 'Reading saved design library…') el('library-status').textContent = 'Library refresh interrupted. Refresh again to inspect saved work.'
    }
    update()
  }
  const close = () => { cancelRequest(); dialog.close() }
  el('close').addEventListener('click', close)
  dialog.addEventListener('cancel', cancelRequest)
  for (const input of Object.values(fields)) input.addEventListener('input', () => { ++generation; invalidate(); update() })
  for (const side of ['left', 'right']) el(side).addEventListener('change', () => { ++generation; clearComparison(); update() })
  el('fork-source').addEventListener('change', update)
  el('catalogue').addEventListener('click', () => run(async (token) => {
    const previous = { left: el('left').value, right: el('right').value }
    entries = []; clearComparison(); update()
    el('library-status').textContent = 'Reading saved design library…'
    el('library-issues').textContent = ''
    try {
      const catalogue = await request('catalogue', {})
      const states = ['draft', 'built', 'unconfirmed', 'missing-draft', 'corrupt-or-unreadable-draft', 'invalid-name', 'unreadable-design']
      if (catalogue?.contract_id !== 'moonrobo.design-catalogue.v1' || catalogue.physical_execution_allowed !== false || catalogue.limit !== 40 || typeof catalogue.truncated !== 'boolean' || !Array.isArray(catalogue.entries) || catalogue.entries.length > 40 || catalogue.entries.some((entry) => !entry || typeof entry.design_id !== 'string' || typeof entry.revision !== 'string' || typeof entry.name !== 'string' || typeof entry.message !== 'string' || typeof entry.recorded_at !== 'string' || !states.includes(entry.state) || typeof entry.selectable !== 'boolean' || (entry.selectable && (!SLUG.test(entry.design_id) || !SLUG.test(entry.revision) || !['draft', 'built', 'unconfirmed'].includes(entry.state) || !/^sha256:[0-9a-f]{64}$/.test(entry.design_digest)))) || new Set(catalogue.entries.map(libraryKey)).size !== catalogue.entries.length) throw new Error('The host returned an unsupported saved-design catalogue.')
      if (token !== generation) return
      entries = catalogue.entries
      const document = root.ownerDocument || globalThis.document
      for (const side of ['left', 'right']) {
        const option = document.createElement('option'); option.value = ''; option.textContent = 'Choose a saved revision'
        const options = [option]
        for (const entry of entries) {
          const option = document.createElement('option')
          option.value = libraryKey(entry); option.textContent = `${entry.name} · ${entry.design_id} / ${entry.revision || '(no revision)'} · ${entry.state}`; option.disabled = !entry.selectable
          options.push(option)
        }
        el(side).replaceChildren(...options)
        el(side).value = entries.some((entry) => entry.selectable && libraryKey(entry) === previous[side]) ? previous[side] : ''
      }
      el('library-issues').textContent = entries.filter((entry) => entry.message).map((entry) => `${libraryKey(entry)} · ${entry.message}`).join('\n')
      el('library-status').textContent = `${entries.length ? `${entries.length} saved entries shown.` : catalogue.truncated ? 'No entries in the scanned portion.' : 'No saved revisions found.'} ${catalogue.truncated ? 'Library limit reached (40 entries/design directories/revisions per design). More saved work may exist; use exact-ID re-open below.' : 'Read-only library refreshed.'}`
      message('Library refreshed. Your editable fields were kept.')
    } catch (error) {
      if (token === generation) el('library-status').textContent = 'Library unavailable. Previous comparison cleared; your editable fields were kept.'
      throw error
    }
  }))
  const inspectEntry = async (entry) => {
    const view = await request('open', { design_id: entry.design_id, revision: entry.revision })
    const { design } = await verifyView(view, entry.design_id, entry.revision)
    if (view.draft.design_digest !== entry.design_digest) throw new Error('Saved draft changed since the library was read. Refresh the library before continuing.')
    return { view, design, entry }
  }
  el('compare').addEventListener('click', () => run(async (token) => {
    const left = entryFor('left'), right = entryFor('right')
    clearComparison()
    if (!left || !right) throw new Error('Choose two readable saved revisions first.')
    const a = await inspectEntry(left)
    const b = libraryKey(left) === libraryKey(right) ? a : await inspectEntry(right)
    if (token !== generation) return
    inspected = { left: a, right: b }
    for (const [side, data] of Object.entries(inspected)) el(`${side}-summary`).textContent = `${data.design.mission.name || data.entry.design_id}\n${libraryKey(data.entry)} · ${data.view.state}\nSaved ${data.view.draft.recorded_at}\n${data.view.draft.design_digest}${data.view.state === 'unconfirmed' ? '\nPartial or changed build evidence; only the verified draft is comparable.' : ''}`
    const rows = compareDesigns(a.design, b.design)
    for (const [group, target] of [['Task loop', 'diff-loop'], ['Mechanisms', 'diff-mechanisms'], ['Scenarios', 'diff-scenarios'], ['Speed (m/s)', 'diff-speed']]) el(target).textContent = rows.filter((row) => row.group === group).map((row) => `${row.changed ? 'Changed' : 'Same'} · ${row.label}\nA: ${row.left}\nB: ${row.right}`).join('\n\n')
    const count = rows.filter((row) => row.changed).length
    el('comparison-status').textContent = `${count} changed field${count === 1 ? '' : 's'} across task loop, mechanisms, scenarios and speed.${a === b ? ' Same saved revision selected twice.' : ''} This does not evaluate mission performance.`
    message('Saved revisions inspected. Fork either draft into a new editable revision.')
  }))
  el('fork').addEventListener('click', () => run(async (token) => {
    const source = inspected?.[el('fork-source').value || 'left']
    if (!source) throw new Error('Inspect saved revisions before forking.')
    const revision = el('fork-revision').value.trim()
    if (!SLUG.test(revision) || revision === source.entry.revision) throw new Error('Choose a new lowercase revision name (1–64 characters), different from the source.')
    if (entries.some((entry) => entry.design_id === source.entry.design_id && entry.revision === revision)) throw new Error('That revision already exists in the library. Choose a new name.')
    if (!permitReplace()) return
    const fresh = await inspectEntry(source.entry)
    if (token !== generation) return
    populate({ ...fresh.design, revision }); invalidate()
    message(`Forked ${libraryKey(source.entry)} into editable ${source.entry.design_id}/${revision}. Review and explicitly save; nothing was written or built.`)
  }))
  el('template').addEventListener('click', () => { if (busy || !permitReplace()) return; ++generation; populate(excavationDraft()); invalidate(); message('Edit this starting concept, give it a design ID and save a revision.'); update() })
  el('open').addEventListener('click', () => run(async (token) => {
    if (!permitReplace()) return
    const { id, revision } = selected(); invalidate()
    const view = await request('open', { design_id: id, revision })
    if (await display(view, id, revision, token) && view.state !== 'unconfirmed') message('Saved revision re-opened. Change the revision name before saving edits.')
  }))
  el('save').addEventListener('click', () => run(async (token) => {
    if (uncertain.has(key())) throw new Error('Re-open this revision before repeating an unconfirmed save.')
    const design = parseDesignFields(Object.fromEntries(fieldIds.map((id) => [id, fields[id].value.trim()])))
    const identity = `${design.design_id}/${design.revision}`
    try {
      const view = await request('save', { design, recorded_at: now() })
      if (await display(view, design.design_id, design.revision, token) && view.state !== 'unconfirmed') message('Draft saved. Build it when the loop, mechanisms and validation scenarios look right.')
    } catch (error) { uncertain.add(identity); if (token === generation) invalidate(); throw new Error(`${error.message} Re-open to check the outcome. Your fields were kept; no retry was made.`) }
  }, true))
  el('build').addEventListener('click', () => run(async (token) => {
    if (!current() || saved.state !== 'draft') throw new Error('Save or re-open the exact draft before building.')
    const draft = saved.draft, identity = key()
    try {
      const view = await request('build', { design_id: draft.design_id, revision: draft.revision, expected_digest: draft.design_digest })
      if (await display(view, draft.design_id, draft.revision, token) && view.state === 'built') message('Fresh digital revision built and artifact-validated. Your previous robot revisions are unchanged.')
    } catch (error) { uncertain.add(identity); if (token === generation) invalidate(); throw new Error(`${error.message} Build outcome unconfirmed. Re-open this revision; no automatic retry was made.`) }
  }, true))
  el('export').addEventListener('click', () => run(async (token) => {
    if (!current() || saved.state !== 'built') throw new Error('Re-open the exact built revision before exporting.')
    const draft = saved.draft
    const selectedPackageDigest = saved.package.package_digest
    const envelope = await request('export', { design_id: draft.design_id, revision: draft.revision, expected_digest: draft.design_digest })
    await inspectSimulationInput(envelope, draft.design_id, draft.revision)
    if (envelope.package_digest !== selectedPackageDigest) throw new Error('The built package changed after selection. Re-open before exporting.')
    if (token !== generation) return
    download(envelope, draft.design_id, draft.revision)
    el('export-status').textContent = 'Simulation-input package downloaded with exact source bindings. Import it in MoonMoon and add mission/site evidence; no simulation was run.'
    message('Download ready. This package is digital robot input only.')
  }))
  update()
  return { whenIdle: () => lastTask }
}
