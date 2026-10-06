// Inert digital evidence only. This module never calls a runtime, provider,
// physical-command, retry, or Book acknowledgement endpoint.
const API = '/api/moonrobo/digital-trials'
const STATES = new Set(['digital-ready', 'blocked', 'unknown'])

export async function readExactTrialFile(file) {
  if (!file) throw new Error('Choose a file first.')
  // Keep CRLF, whitespace, and BOM unchanged. Reject invalid UTF-8 rather than
  // replacing bytes and accidentally claiming exact frozen-result evidence.
  return new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(await file.arrayBuffer())
}

export function inspectDigitalTrial(payload, trialId) {
  const record = payload?.record
  if (!record || typeof record !== 'object' || Array.isArray(record)) {
    throw new Error('The host response has no digital-trial record. Re-open the trial to inspect its outcome.')
  }
  if (record.contract_id !== 'moonrobo.digital-trial.v1') {
    throw new Error('The host returned an unsupported digital-trial contract. Re-open is required.')
  }
  if (record.import_request?.trial_id !== trialId || record.binding?.trial_id !== trialId) {
    throw new Error('The host returned a different trial. Re-open the requested trial before continuing.')
  }
  const revision = record.revision
  if (!Number.isSafeInteger(revision) || revision < 0) {
    throw new Error('The host response has no usable revision. Re-open the trial before continuing.')
  }
  const claimedState = payload.state
  return {
    record,
    trialId,
    revision,
    state: STATES.has(claimedState) ? claimedState : 'unknown',
    digitalResultState: STATES.has(payload.digital_result_state) ? payload.digital_result_state : 'unknown',
    bindingState: ['matched', 'blocked', 'unknown'].includes(payload.binding_state) ? payload.binding_state : 'unknown',
    acknowledgementState: payload.acknowledgement_state === 'confirmed' ? 'confirmed' : 'unknown',
    // Never elevate an imported claim to local physical authority.
    physicalAuthority: false,
  }
}

export function downloadTrialExport(payload, trialId, document = globalThis.document, url = globalThis.URL) {
  const blob = new Blob([JSON.stringify(payload, null, 2) + '\n'], { type: 'application/json' })
  const href = url.createObjectURL(blob)
  const link = document.createElement('a')
  link.href = href
  link.download = `digital-trial-${trialId.replace(/[^a-zA-Z0-9_-]/g, '_')}-pending-book.json`
  document.body.appendChild(link)
  try {
    link.click()
  } finally {
    link.remove()
    url.revokeObjectURL(href)
  }
}

const PANEL = `
  <header class="digital-trials-heading">
    <div><p class="eyebrow">MoonRobo / MoonMoon</p><h2 id="digital-trials-title">Digital trial inspection</h2></div>
    <button id="dt-close" type="button" aria-label="Close digital trial inspection">Close</button>
  </header>
  <p class="digital-trials-boundary">Digital evidence only. Local physical authority: <strong>false</strong>. No robot execution or physical approval is available here.</p>
  <p id="dt-status" role="status" aria-live="polite">No trial loaded. Choose your MoonMoon files or re-open an existing trial.</p>
  <div class="digital-trials-grid">
    <section aria-labelledby="dt-import-title">
      <h3 id="dt-import-title">1. Import or re-open</h3>
      <label for="dt-trial-id">Trial ID</label>
      <input id="dt-trial-id" type="text" autocomplete="off" spellcheck="false" />
      <label for="dt-session-id">Session ID</label>
      <input id="dt-session-id" type="text" autocomplete="off" spellcheck="false" />
      <label for="dt-dossier-file">Exact MoonMoon dossier envelope file</label>
      <input id="dt-dossier-file" type="file" accept=".json,application/json" />
      <small id="dt-dossier-file-status">No file chosen</small>
      <label for="dt-result-file">Exact MoonMoon digital result file</label>
      <input id="dt-result-file" type="file" accept=".json,application/json" />
      <small id="dt-result-file-status">No file chosen</small>
      <p class="digital-trials-help">Files stay unmodified. No example trial is preloaded. Drafts stay in this panel when it closes or a request fails; a page reload clears them.</p>
      <div class="digital-trials-actions">
        <button id="dt-import" type="button">Import digital evidence</button>
        <button id="dt-reopen" type="button">Re-open trial</button>
      </div>
    </section>
    <section aria-labelledby="dt-inspection-title">
      <h3 id="dt-inspection-title">2. Inspect evidence</h3>
      <p id="dt-state" class="digital-trials-state" data-state="unknown">Digital-only state: unknown</p>
      <p id="dt-evidence-state">Digital result: unknown · binding: unknown · import acknowledgement: unknown</p>
      <p id="dt-revision">Revision: unavailable</p>
      <p id="dt-calibration" class="digital-trials-warning">Calibration evidence is absent or unqualified until inspected. Digital readiness does not qualify physical calibration.</p>
      <p class="digital-trials-help">The complete host record and view below include evidence, calibration warnings, attempt history, and review notes. They do not grant physical authority.</p>
      <pre id="dt-inspection" tabindex="0" aria-label="Digital trial host record">No host record loaded.</pre>
    </section>
    <section aria-labelledby="dt-event-title">
      <h3 id="dt-event-title">3. Record an inert event</h3>
      <label for="dt-event-id">Unique event ID</label>
      <input id="dt-event-id" type="text" autocomplete="off" spellcheck="false" />
      <label for="dt-reviewer">Reviewer name (required for reconciliation and review)</label>
      <input id="dt-reviewer" type="text" autocomplete="off" />
      <label for="dt-note">Event explanation or review note (required for every event)</label>
      <textarea id="dt-note" rows="3"></textarea>
      <p class="digital-trials-help">Every event uses the loaded revision. Nothing retries automatically. If a request has an uncertain outcome, re-open the trial before taking another action.</p>
      <button id="dt-lost-ack" type="button">Record lost import acknowledgement</button>
      <p class="digital-trials-help">This records only loss of an inert import acknowledgement. It does not simulate a robot command, dispatch, or retry.</p>
      <label for="dt-proof-file">Manual reconciliation: exact frozen result file</label>
      <input id="dt-proof-file" type="file" accept=".json,application/json" />
      <small id="dt-proof-file-status">No proof chosen</small>
      <p class="digital-trials-help">For an unknown import acknowledgement only: select the same frozen result bytes from this attempt and supply a reviewer name and note. Reconciliation cannot start a new attempt or execute anything.</p>
      <button id="dt-reconcile" type="button">Reconcile this attempt</button>
      <button id="dt-review" type="button">Record named review</button>
      <p class="digital-trials-help">A review is an attributed note only. It does not grant execution, calibration, or physical authority.</p>
    </section>
    <section aria-labelledby="dt-export-title">
      <h3 id="dt-export-title">4. Export for Book retention</h3>
      <p>After a failed digital result or inert acknowledgement-loss incident, record a named review of the latest revision, then download the host export as JSON for later Book retention.</p>
      <button id="dt-export" type="button">Download pending Book export</button>
      <p id="dt-export-status" class="digital-trials-warning">Book retention is pending. A download is not a Book acknowledgement.</p>
      <pre id="dt-export-preview" tabindex="0" aria-label="Pending Book export">No export requested.</pre>
    </section>
  </div>`

export function mountDigitalTrials({
  root,
  dialog,
  launcher,
  hostUrl = '',
  fetchImpl = (...args) => globalThis.fetch(...args),
  now = () => Date.now(),
  download = downloadTrialExport,
} = {}) {
  if (!root || !dialog || !launcher) return null
  root.innerHTML = PANEL
  const find = (id) => root.querySelector(`#dt-${id}`)
  const fields = Object.fromEntries([
    'trial-id', 'session-id', 'dossier-file', 'result-file', 'proof-file',
    'event-id', 'reviewer', 'note',
  ].map((id) => [id, find(id)]))
  const buttons = Object.fromEntries(['import', 'reopen', 'lost-ack', 'reconcile', 'review', 'export'].map((id) => [id, find(id)]))
  const base = hostUrl.replace(/\/$/, '') + API
  const files = { dossier: null, result: null, proof: null }
  const fileVersions = { dossier: 0, result: 0, proof: 0 }
  const uncertainTrials = new Set()
  let inspection = null
  let busy = false
  let lastTask = Promise.resolve()
  let fileReads = 0

  const trialId = () => fields['trial-id'].value.trim()
  const message = (value, error = false) => {
    find('status').textContent = value
    find('status').dataset.error = String(error)
  }
  const updateButtons = () => {
    const blocked = busy || fileReads > 0
    const current = inspection?.trialId === trialId()
    const uncertain = uncertainTrials.has(trialId())
    buttons.import.disabled = blocked || uncertain
    buttons.reopen.disabled = blocked
    for (const id of ['lost-ack', 'reconcile', 'review', 'export']) {
      buttons[id].disabled = blocked || !current || uncertain
    }
    if (current && inspection.acknowledgementState === 'unknown') {
      buttons['lost-ack'].disabled = true
    }
    if (current && inspection.acknowledgementState !== 'unknown') buttons.reconcile.disabled = true
    for (const field of Object.values(fields)) field.disabled = busy
    root.setAttribute('aria-busy', String(busy))
  }
  const resetInspection = () => {
    inspection = null
    find('state').textContent = 'Digital-only state: unknown'
    find('state').dataset.state = 'unknown'
    find('evidence-state').textContent = 'Digital result: unknown · binding: unknown · import acknowledgement: unknown'
    find('revision').textContent = 'Revision: unavailable'
    find('inspection').textContent = 'No host record loaded for this trial.'
    find('calibration').textContent = 'Calibration evidence is absent or unqualified until inspected. Digital readiness does not qualify physical calibration.'
    find('export-preview').textContent = 'No export requested for this trial.'
    find('export-status').textContent = 'Book retention is pending. A download is not a Book acknowledgement.'
  }
  const display = (payload, id) => {
    inspection = inspectDigitalTrial(payload, id)
    find('state').textContent = `Digital-only state: ${inspection.state}`
    find('state').dataset.state = inspection.state
    find('evidence-state').textContent = `Digital result: ${inspection.digitalResultState} · binding: ${inspection.bindingState} · import acknowledgement: ${inspection.acknowledgementState}`
    find('revision').textContent = `Revision: ${inspection.revision}`
    find('inspection').textContent = JSON.stringify(payload, null, 2)
    const warnings = [...(Array.isArray(payload.blockers) ? payload.blockers : []), ...(Array.isArray(payload.unknowns) ? payload.unknowns : [])]
    find('calibration').textContent = warnings.length
      ? `Evidence warnings: ${warnings.map((warning) => typeof warning === 'string' ? warning : JSON.stringify(warning)).join('; ')}. Digital-ready is digital evidence only; this panel never qualifies physical calibration.`
      : 'Check calibration in the host record. Any absent or unqualified calibration remains a warning. Digital-ready is digital evidence only; this panel never qualifies physical calibration.'
    find('export-status').textContent = 'Book retention is pending. A download is not a Book acknowledgement.'
    find('export-preview').textContent = 'No export requested for this revision.'
  }
  const request = async (path, body) => {
    const response = await fetchImpl(base + path, {
      method: body === undefined ? 'GET' : 'POST',
      headers: body === undefined ? { Accept: 'application/json' } : { Accept: 'application/json', 'Content-Type': 'application/json' },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      cache: 'no-store',
    })
    let payload
    try {
      payload = await response.json()
    } catch {
      throw new Error(`Host response was not readable JSON (HTTP ${response.status}).`)
    }
    if (!response.ok) {
      const detail = typeof payload?.message === 'string' ? payload.message
        : typeof payload?.error === 'string' ? payload.error : 'Host rejected the request.'
      throw new Error(`HTTP ${response.status}: ${detail}`)
    }
    return payload
  }
  const requireId = () => {
    const id = trialId()
    if (!id) throw new Error('Enter a trial ID.')
    return id
  }
  const requireCurrent = () => {
    const id = requireId()
    if (!inspection || inspection.trialId !== id || uncertainTrials.has(id)) {
      throw new Error('Re-open this trial to load its current host revision first.')
    }
    return id
  }
  const run = (action) => {
    if (busy || fileReads > 0) return lastTask
    busy = true
    updateButtons()
    lastTask = Promise.resolve().then(action).catch((error) => {
      message(error.message || 'The request failed. Your draft has been kept.', true)
    }).finally(() => {
      busy = false
      updateButtons()
    })
    return lastTask
  }
  const mutate = async (id, path, body) => {
    try {
      const payload = await request(path, body)
      display(payload, id)
      uncertainTrials.delete(id)
      return payload
    } catch (error) {
      uncertainTrials.add(id)
      // The previous receipt cannot describe the outcome of this request.
      find('state').textContent = 'Digital-only state: unknown'
      find('state').dataset.state = 'unknown'
      find('revision').textContent = 'Revision: uncertain; re-open required'
      throw new Error(`${error.message} Outcome unconfirmed; draft kept. Re-open this trial before another action. No automatic retry was made.`)
    }
  }

  launcher.addEventListener('click', () => dialog.showModal())
  find('close').addEventListener('click', () => dialog.close())
  fields['trial-id'].addEventListener('input', () => {
    if (inspection?.trialId !== trialId()) resetInspection()
    if (uncertainTrials.has(trialId())) message('This trial has an unconfirmed request. Re-open it before another action.', true)
    updateButtons()
  })

  for (const kind of ['dossier', 'result', 'proof']) {
    fields[`${kind}-file`].addEventListener('change', async () => {
      const version = ++fileVersions[kind]
      const file = fields[`${kind}-file`].files?.[0]
      files[kind] = null
      const status = find(`${kind}-file-status`)
      status.textContent = file ? `Reading ${file.name}…` : 'No file chosen'
      if (!file) {
        updateButtons()
        return
      }
      fileReads += 1
      updateButtons()
      try {
        const text = await readExactTrialFile(file)
        if (version !== fileVersions[kind]) return
        if (!text) throw new Error('The selected file is empty.')
        files[kind] = text
        status.textContent = `${file.name} · exact UTF-8 text loaded`
      } catch (error) {
        if (version !== fileVersions[kind]) return
        status.textContent = `${file.name} · could not read exact UTF-8 text`
        message(error.message || 'The file could not be read.', true)
      } finally {
        fileReads -= 1
        updateButtons()
      }
    })
  }

  buttons.import.addEventListener('click', () => run(async () => {
    const id = requireId()
    if (uncertainTrials.has(id)) throw new Error('Re-open this trial before repeating an unconfirmed import.')
    const sessionId = fields['session-id'].value.trim()
    if (!sessionId) throw new Error('Enter the MoonMoon session ID.')
    if (!files.dossier || !files.result) throw new Error('Choose both the exact dossier envelope and digital result files.')
    await mutate(id, '/import', { trial_id: id, session_id: sessionId, dossier_text: files.dossier, result_text: files.result })
    message('Digital evidence imported. Inspect the state and warnings; physical authority remains false.')
  }))
  buttons.reopen.addEventListener('click', () => run(async () => {
    const id = requireId()
    // A failed refresh must not leave an old revision presented as current.
    // Inputs and exact file drafts are deliberately outside this reset.
    resetInspection()
    const payload = await request(`/${encodeURIComponent(id)}`)
    display(payload, id)
    uncertainTrials.delete(id)
    message(inspection.acknowledgementState === 'unknown'
      ? 'Re-opened with an unknown import acknowledgement. Reconcile the same attempt with manual proof; nothing retries automatically.'
      : inspection.state === 'unknown'
        ? 'Re-opened with unknown evidence or binding. Inspect the warnings; a review note cannot resolve missing calibration or grant authority.'
      : 'Re-opened the host record. Your file selections and review draft have been kept.')
  }))
  for (const kind of ['lost-ack', 'reconcile', 'review']) {
    buttons[kind].addEventListener('click', () => run(async () => {
      const id = requireCurrent()
      if (inspection.acknowledgementState === 'unknown' && kind === 'lost-ack') throw new Error('The import acknowledgement is already unknown. Reconcile the same attempt with manual proof.')
      if (inspection.acknowledgementState !== 'unknown' && kind === 'reconcile') throw new Error('Manual reconciliation is only for an unknown import acknowledgement.')
      const eventId = fields['event-id'].value.trim()
      if (!eventId) throw new Error('Enter a unique event ID.')
      if (kind === 'reconcile' && !files.proof) throw new Error('Choose the exact frozen result file from this attempt as manual proof.')
      const reviewer = fields.reviewer.value.trim()
      const note = fields.note.value
      if ((kind === 'review' || kind === 'reconcile') && (!reviewer || !note.trim())) throw new Error('Enter both a reviewer name and a review note.')
      if (!note.trim()) throw new Error('Enter an explanation for the lost inert import acknowledgement.')
      await mutate(id, '/event', {
        trial_id: id,
        expected_revision: inspection.revision,
        event_id: eventId,
        kind,
        proof_text: kind === 'reconcile' ? files.proof : '',
        reviewer: kind === 'lost-ack' ? '' : reviewer,
        note,
        // MoonBit Int64 uses a JSON string on this host's native wire contract.
        now_ms: String(now()),
      })
      message(kind === 'lost-ack'
        ? 'Recorded loss of the inert import acknowledgement. Reconcile the same attempt with its exact frozen result; no retry was made.'
        : kind === 'review'
          ? 'Named review recorded as a note. No authority was granted.'
          : 'Manual reconciliation recorded for this attempt. Inspect the returned digital-only state.')
    }))
  }
  buttons.export.addEventListener('click', () => run(async () => {
    const id = requireCurrent()
    const payload = await request('/export', { trial_id: id })
    if (payload?.contract_id !== 'moonrobo.digital-incident-export.v1' ||
        payload.retention_state !== 'pending-book-review' ||
        payload.physical_execution_allowed !== false ||
        !payload.submission || !Array.isArray(payload.evidence)) {
      throw new Error('The host did not return a valid pending Book incident export. No download or Book acknowledgement was created.')
    }
    find('export-preview').textContent = JSON.stringify(payload, null, 2)
    download(payload, id)
    find('export-status').textContent = 'Export download prepared. Book retention remains pending; no Book acknowledgement has been received here.'
    message('Pending Book export prepared for download. This does not confirm Book retention.')
  }))

  updateButtons()
  return { whenIdle: () => lastTask }
}
