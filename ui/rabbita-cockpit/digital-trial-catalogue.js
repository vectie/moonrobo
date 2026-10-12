// Retained evidence viewer. Every request is GET; this module has no mutation,
// simulation, replay, repair, execution or Book acknowledgement action.
import { createTrialComparisonDossier, verifyTrialComparisonDossier, downloadComparisonDossier, DOSSIER_LIMIT } from './trial-comparison-dossier.js'
import { METRICS, metric, inspectRetainedTrial, compareRetainedTrials } from './retained-trial-evidence.js'
export { inspectRetainedTrial, compareRetainedTrials } from './retained-trial-evidence.js'
const API = '/api/moonrobo/digital-trials'
const LIMIT = 32
const SLUG = /^[a-zA-Z0-9_-]{1,100}$/
const text = (value) => typeof value === 'string' && value.length ? value : 'unavailable'
const list = (values) => Array.isArray(values) ? values.map((value) => typeof value === 'string' ? value : JSON.stringify(value)).join('\n') || 'None recorded' : 'unavailable'

const sidePanel = (side, label) => `
  <section class="retained-trial-side" aria-labelledby="rt-${side}-title">
    <h4 id="rt-${side}-title">Trial ${label}</h4>
    <label for="rt-${side}">Choose retained trial ${label}</label>
    <select id="rt-${side}"><option value="">Refresh catalogue first</option></select>
    <p id="rt-${side}-status" role="status">No trial selected</p>
    <button id="rt-${side}-continue" type="button" disabled>Continue to review trial ${label}</button>
    <h5>Frozen digital outcome</h5><pre id="rt-${side}-outcome">Unavailable</pre>
    <h5>Frozen identity and digests</h5><pre id="rt-${side}-identity">Unavailable</pre>
    <h5>Native recorded metrics</h5><pre id="rt-${side}-metrics">Unavailable</pre>
    <h5>Current local artifact binding</h5><pre id="rt-${side}-binding">Unavailable</pre>
    <h5>Import acknowledgement, reviews and events</h5><pre id="rt-${side}-history">Unavailable</pre>
    <h5>Frozen provenance and replay receipts</h5><pre id="rt-${side}-references">Unavailable</pre>
    <details><summary>Complete raw host evidence for trial ${label}</summary><pre id="rt-${side}-raw" tabindex="0">No host evidence loaded</pre></details>
  </section>`

export const RETAINED_TRIAL_PANEL = `
  <section class="retained-trials" aria-labelledby="rt-title">
    <h3 id="rt-title">Retained digital trial catalogue</h3>
    <p>Read-only inspection and two-trial comparison. Frozen outcomes, current local files and inert event history are separate evidence. No re-simulation, repair, physical authority or Book acceptance.</p>
    <button id="rt-refresh" type="button">Refresh retained trials</button>
    <p id="rt-status" role="status" aria-live="polite">Refresh to discover retained trials. Nothing is loaded automatically.</p>
    <pre id="rt-issues" aria-label="Unavailable retained trials"></pre>
    <div class="retained-trials-grid">${sidePanel('left', 'A')}${sidePanel('right', 'B')}</div>
    <h4>Two-trial comparison</h4>
    <p id="rt-comparison-status" role="status">Choose and load both trials. No comparison is available.</p>
    <pre id="rt-comparison" aria-label="Native metric comparison">Unavailable</pre>
    <button id="rt-dossier-export" type="button" disabled>Download comparison dossier (Markdown + JSON)</button>
    <p id="rt-dossier-status" role="status">Load both trials to export the inspected evidence. No new host reads are made by export.</p>
    <label for="rt-dossier-file">Verify and reopen a portable dossier locally (no native import)</label>
    <input id="rt-dossier-file" type="file" accept=".json,application/json" />
    <label for="rt-dossier-markdown-file">Optional companion Markdown (checks this exact pair)</label>
    <input id="rt-dossier-markdown-file" type="file" accept=".md,text/markdown,text/plain" />
    <p id="rt-dossier-file-status" role="status">No portable dossier selected.</p>
    <pre id="rt-dossier-preview" tabindex="0" aria-label="Verified historical portable dossier"></pre>
  </section>`

export function mountRetainedTrials({ root, dialog, hostUrl = '', fetchImpl = (...args) => globalThis.fetch(...args), now = () => Date.now(), downloadDossier = downloadComparisonDossier, continueToReview }) {
  const el = (id) => root.querySelector(`#rt-${id}`)
  const doc = root.ownerDocument || globalThis.document
  const observedHost = () => {
    try { return new URL(hostUrl || globalThis.location?.href).origin }
    catch { return 'same-origin host (origin unavailable)' }
  }
  const versions = { left: 0, right: 0 }
  const loaded = { left: null, right: null }
  const pending = new Set()
  let refreshVersion = 0
  let selectable = new Set()
  let exporting = false
  let fileVersion = 0
  const sections = ['outcome', 'identity', 'metrics', 'binding', 'history', 'references', 'raw']
  const track = (task) => { pending.add(task); task.finally(() => pending.delete(task)); return task }
  const comparison = () => {
    for (const side of ['left', 'right']) el(`${side}-continue`).disabled = !loaded[side] || !continueToReview
    const view = compareRetainedTrials(loaded.left, loaded.right)
    el('comparison-status').textContent = view.message
    el('comparison').textContent = view.state === 'incomplete' ? 'Unavailable' : view.rows.map((row) => `${row.label} (${row.unit}) · A: ${row.a ?? 'unavailable'} · B: ${row.b ?? 'unavailable'} · Δ B−A: ${row.delta ?? 'unavailable'}`).join('\n')
    el('dossier-export').disabled = exporting || !loaded.left || !loaded.right
  }
  const clearSide = (side, status) => {
    versions[side] += 1
    loaded[side] = null
    fileVersion += 1
    el('dossier-preview').textContent = ''
    el('dossier-file').value = ''
    el('dossier-markdown-file').value = ''
    el('dossier-file-status').textContent = 'Inspection changed. Choose portable files again to verify historical evidence.'
    el('dossier-status').textContent = 'Inspection changed. Load both trials before exporting.'
    el(`${side}-status`).textContent = status
    for (const section of sections) el(`${side}-${section}`).textContent = 'Unavailable'
    comparison()
  }
  const get = async (suffix, captureExact = false) => {
    const response = await fetchImpl(hostUrl.replace(/\/$/, '') + API + suffix, { method: 'GET', headers: { Accept: 'application/json' }, cache: 'no-store' })
    if (!response.ok) throw new Error(`Host could not read retained evidence (HTTP ${response.status}).`)
    if (captureExact) {
      const payloadText = await response.text()
      return { payload: JSON.parse(payloadText), payloadText }
    }
    return response.json()
  }
  const render = (side, view) => {
    const { payload, record, binding: b, evidence: e } = view
    el(`${side}-status`).textContent = `Inspected ${view.id} · retained revision ${record.revision}. Digital evidence only; physical authority false.`
    el(`${side}-outcome`).textContent = `Decision: ${b.digital_result}\nScenario: ${text(e.scenario_id)} / ${text(e.scenario_kind)}\nOutcome: ${text(e.scenario_outcome)}\nFinal state: ${text(e.final_state)}\nClaim: ${text(e.evidence_claim)}\nWhole-grid status: ${text(e.whole_grid_status)}\nFrozen blockers:\n${list(b.blockers)}\nFrozen limitations:\n${list(b.limitations)}`
    el(`${side}-identity`).textContent = `Trial: ${view.id}\nSession: ${text(b.session_id)}\nAttempt: ${text(b.attempt_id)}\nProof: ${text(b.proof_id)}\nRobot: ${text(b.robot_id)} / ${text(b.robot_revision)}\nDossier: ${text(b.dossier_digest)}\nResult: ${text(b.result_digest)}\nBaseline: ${text(b.baseline_digest)}\nBaseline binding: ${view.verifiedBaseline ? 'verified' : 'unavailable'}\nProfile: ${text(b.profile_digest)}\nURDF: ${text(b.urdf_digest)}\nValidation: ${text(b.validation_digest)}\nCalibration: ${text(b.calibration_digest)}`
    el(`${side}-metrics`).textContent = METRICS.map(([key, label, unit]) => `${label} (${unit}): ${metric(e, key, unit) ?? 'unavailable'}`).join('\n')
    el(`${side}-binding`).textContent = `Current binding: ${text(payload.binding_state)}\nCurrent artifact blockers:\n${list(payload.current_binding_blockers)}\nCurrent artifact unknowns:\n${list(payload.current_binding_unknowns)}\nProfile path: ${text(b.profile_path)}\nURDF path: ${text(b.urdf_path)}\nValidation path: ${text(b.validation_path)}\nCalibration source digest: ${text(b.calibration_source_digest)}\nFrozen calibration evidence: ${JSON.stringify(b.calibration ?? null)}\nA file match never qualifies current hardware.`
    const reviews = record.events.filter((event) => event.kind === 'review')
    el(`${side}-history`).textContent = `Import acknowledgement: ${text(payload.acknowledgement_state)}\nRetained revision: ${record.revision}\nNamed reviews (${reviews.length}):\n${reviews.map((event) => `${event.reviewer}: ${event.note}`).join('\n') || 'None recorded'}\nOrdered inert events (${record.events.length}):\n${record.events.map((event, index) => `${index + 1}. ${text(event.kind)} · ${text(event.event_id)} · time ${event.now_ms ?? 'unavailable'} · ${event.reviewer || 'unattributed'}\n${event.note || ''}`).join('\n') || 'None recorded'}\nBook retention: ${text(payload.retention_state)}. This view does not confirm Book acceptance.`
    el(`${side}-references`).textContent = `Design: ${text(e.design_ref)}\nResult: ${text(e.result_ref)}\nProvenance: ${text(e.provenance_ref)}\nReplay: ${text(e.replay_ref)}\nRecorded replays: ${e.replay_completed ?? 'unavailable'} / ${e.replay_required ?? 'unavailable'} required\nByte equivalence: ${e.replay_byte_equivalent === true ? 'verified frozen receipt' : 'unavailable'}\nProvenance digests:\n${list(e.provenance_source_digests)}\nNo replay was run by this view.`
    el(`${side}-raw`).textContent = JSON.stringify(payload, null, 2)
  }
  for (const side of ['left', 'right']) {
    el(`${side}-continue`).addEventListener('click', () => {
      const view = loaded[side], version = versions[side]
      if (!view || !continueToReview) return
      return track(Promise.resolve(continueToReview(view.id, () => loaded[side] === view && versions[side] === version)))
    })
    el(side).addEventListener('change', () => {
      const id = el(side).value
      clearSide(side, id ? 'Loading selected retained evidence…' : 'No trial selected')
      if (!id) return
      if (!selectable.has(id)) { el(`${side}-status`).textContent = 'Selection is unavailable in the current catalogue'; return }
      const version = versions[side]
      return track((async () => {
        try {
          const { payload, payloadText } = await get(`/${encodeURIComponent(id)}`, true)
          const view = { ...inspectRetainedTrial(payload, id), observedAt: now(), host: observedHost(), payloadText }
          if (versions[side] !== version || el(side).value !== id) return
          render(side, view)
          loaded[side] = view
        } catch (error) {
          if (versions[side] !== version) return
          el(`${side}-status`).textContent = `Unavailable: ${error.message}. Select again or refresh; no repair or retry was attempted.`
        }
        comparison()
      })())
    })
  }
  el('refresh').addEventListener('click', () => {
    const version = ++refreshVersion
    selectable = new Set()
    for (const side of ['left', 'right']) { el(side).value = ''; el(side).disabled = true; clearSide(side, 'Refresh in progress; previous inspection cleared') }
    el('status').textContent = 'Reading retained trial catalogue…'
    el('issues').textContent = ''
    return track((async () => {
      try {
        const catalogue = await get('')
        if (version !== refreshVersion) return
        if (catalogue?.contract_id !== 'moonrobo.digital-trial-catalogue.v1' || catalogue.physical_execution_allowed !== false ||
            catalogue.limit !== LIMIT || !Array.isArray(catalogue.entries) || catalogue.entries.length > LIMIT ||
            !['available', 'missing', 'empty', 'unreadable', 'truncated'].includes(catalogue.state) || typeof catalogue.truncated !== 'boolean' ||
            new Set(catalogue.entries.map((entry) => entry.trial_id)).size !== catalogue.entries.length) throw new Error('Invalid or over-limit catalogue response')
        const valid = catalogue.entries.filter((entry) => entry.state === 'verified' && entry.selectable === true && SLUG.test(entry.trial_id))
        selectable = new Set(valid.map((entry) => entry.trial_id))
        for (const side of ['left', 'right']) {
          const options = [doc.createElement('option'), ...valid.map((entry) => {
            const option = doc.createElement('option'); option.value = entry.trial_id
            option.textContent = `${entry.trial_id} · ${text(entry.digital_result)} · ${text(entry.robot_id)} / ${text(entry.robot_revision)} · ack ${text(entry.acknowledgement_state)}`
            return option
          })]
          options[0].value = ''; options[0].textContent = 'Choose a retained trial'
          el(side).replaceChildren(...options); el(side).disabled = false
          el(`${side}-status`).textContent = 'No trial selected'
        }
        el('status').textContent = `Catalogue: ${catalogue.state}. ${valid.length} selectable of ${catalogue.entries.length} shown; limit ${LIMIT}.${catalogue.truncated ? ' Truncated: additional trials were not inspected. No completeness claim.' : ''}`
        el('issues').textContent = catalogue.entries.filter((entry) => !selectable.has(entry.trial_id)).map((entry) => `${text(entry.trial_id)} · ${text(entry.state)} · ${text(entry.message)}`).join('\n') || 'No unavailable entries in this bounded listing'
      } catch (error) {
        if (version !== refreshVersion) return
        el('status').textContent = `Catalogue unavailable: ${error.message}. Previous selections and evidence were cleared.`
      }
    })())
  })
  el('dossier-export').addEventListener('click', () => {
    if (exporting || !loaded.left || !loaded.right) return
    const left = loaded.left, right = loaded.right
    exporting = true; comparison()
    el('dossier-status').textContent = 'Preparing exact inspected evidence and integrity digests…'
    return track((async () => {
      try {
        const files = await createTrialComparisonDossier(left, right, now())
        if (loaded.left !== left || loaded.right !== right) return
        downloadDossier(files)
        el('dossier-status').textContent = `Dossier ${files.envelope.export_id}. Two separate downloads requested; delivery is not atomic and your browser may block one. Save both matching filenames and use the optional Markdown check. Historical observations only; no new read, review, native import or Book acceptance.`
      } catch (error) {
        if (loaded.left === left && loaded.right === right) el('dossier-status').textContent = `Dossier unavailable: ${error.message}`
      } finally { exporting = false; comparison() }
    })())
  })
  const reopen = () => {
    const version = ++fileVersion, file = el('dossier-file').files?.[0]
    const markdownFile = el('dossier-markdown-file').files?.[0]
    el('dossier-preview').textContent = ''
    el('dossier-file-status').textContent = file ? 'Verifying portable evidence locally…' : 'No portable dossier selected.'
    if (!file) return
    return track((async () => {
      try {
        if (file.size > DOSSIER_LIMIT) throw new Error('Portable dossier exceeds its size limit.')
        const text = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(await file.arrayBuffer())
        if (markdownFile?.size > DOSSIER_LIMIT) throw new Error('Companion Markdown exceeds its size limit.')
        const markdown = markdownFile ? new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(await markdownFile.arrayBuffer()) : undefined
        const verified = await verifyTrialComparisonDossier(text, markdown)
        if (fileVersion !== version) return
        el('dossier-file-status').textContent = verified.message
        el('dossier-preview').textContent = verified.markdown
      } catch (error) {
        if (fileVersion === version) el('dossier-file-status').textContent = `Portable dossier rejected: ${error.message}`
      }
    })())
  }
  el('dossier-file').addEventListener('change', reopen)
  el('dossier-markdown-file').addEventListener('change', reopen)
  const cancel = () => {
    refreshVersion += 1
    fileVersion += 1
    el('dossier-preview').textContent = ''
    el('dossier-file-status').textContent = 'Panel closed. Choose a file again to verify historical evidence.'
    for (const side of ['left', 'right']) clearSide(side, 'Panel closed; select again for a fresh inspection')
    el('status').textContent = 'Panel closed. Refresh or select again for current retained evidence.'
  }
  dialog?.addEventListener('close', cancel)
  dialog?.addEventListener('cancel', cancel)
  comparison()
  return { whenIdle: async () => { while (pending.size) await Promise.all([...pending]) } }
}
