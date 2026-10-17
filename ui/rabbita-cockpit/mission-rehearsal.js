// Local operator practice only. Deliberately has no network or bridge dependency.
export const REHEARSAL_PANEL = `
<section class="mission-rehearsal" aria-labelledby="mr-title">
  <h3 id="mr-title">Rehearse the task loop</h3>
  <p>Practice sequencing and interruption recovery with the current editable design. This is a manual digital tabletop exercise, not physics, scenario validation, telemetry evidence or hardware readiness. Nothing is dispatched or saved.</p>
  <button id="mr-load" type="button">Load current design into rehearsal</button>
  <label for="mr-speed">Practice speed (m/s, within this design’s bounds)</label><input id="mr-speed" type="number" step="0.01" />
  <p id="mr-status" role="status" aria-live="polite">Load a design to begin.</p>
  <progress id="mr-progress" value="0" max="1" aria-label="Rehearsal steps completed"></progress>
  <ol id="mr-steps" aria-label="Task loop rehearsal"></ol>
  <div class="digital-trials-actions">
    <button id="mr-start" type="button">Start / resume practice</button>
    <button id="mr-next" type="button">Simulate current step completed</button>
    <button id="mr-hold" type="button">Operator hold</button>
    <button id="mr-hazard" type="button">Inject hazard</button>
    <button id="mr-clear" type="button">Clear simulated hazard</button>
    <button id="mr-gap" type="button">Inject telemetry gap</button>
    <button id="mr-restore" type="button">Restore simulated telemetry</button>
  </div>
  <p>Lost telemetry leaves the current step unknown. After restoring the simulated link, choose what your practice evidence shows. Neither restoration nor reconciliation resumes the sequence.</p>
  <button id="mr-done" type="button">Practice evidence: step completed</button>
  <button id="mr-not-started" type="button">Practice evidence: step never started</button>
  <button id="mr-reset" type="button">Reset rehearsal to beginning</button>
  <p>Closing holds an active rehearsal. Editing the design clears it. Reloading the page clears all practice state. Simulation-only; physical authority remains false.</p>
</section>`

export function createRehearsal(design) {
  const speed = design?.constraints?.commanded_speed_mps
  if (design?.mission?.authority !== 'digital-only' || design.mission.robot_class !== 'excavation-haul-rover' || !Array.isArray(design.task_loop) || design.task_loop.length < 4 || design.task_loop.length > 24 || design.task_loop.some((s) => typeof s !== 'string' || !s.trim()) || !Number.isFinite(speed?.min) || !Number.isFinite(speed?.max) || speed.min <= 0 || speed.max < speed.min || speed.max > 0.5) throw new Error('Load a valid bounded digital design first.')
  return { identity: `${design.design_id} / ${design.revision}`, steps: [...design.task_loop], min: speed.min, max: speed.max, speed: speed.min, cursor: 0, state: 'ready', hazard: false, connected: true, unknown: false, physical_execution_allowed: false }
}

export function transitionRehearsal(previous, action, value) {
  const s = { ...previous }
  const require = (condition, message) => { if (!condition) throw new Error(message) }
  if (action === 'reset') return { ...s, cursor: 0, state: 'ready', hazard: false, connected: true, unknown: false }
  if (action === 'speed') {
    require(s.state !== 'running', 'Hold the rehearsal before changing speed.')
    require(Number.isFinite(value) && value >= s.min && value <= s.max, `Practice speed must be within ${s.min}–${s.max} m/s.`)
    return { ...s, speed: value }
  }
  if (action === 'start') {
    require(['ready', 'held'].includes(s.state) && s.cursor < s.steps.length, 'Reset a finished rehearsal before starting again.')
    require(!s.hazard && s.connected && !s.unknown, 'Clear the hazard, restore telemetry and reconcile any unknown step first.')
    s.state = 'running'
  } else if (action === 'next') {
    require(s.state === 'running' && !s.unknown && !s.hazard && s.connected, 'The rehearsal must be running with known conditions to advance.')
    s.cursor += 1
    if (s.cursor === s.steps.length) s.state = 'completed'
  } else if (action === 'hold' || action === 'hazard' || action === 'gap') {
    require(s.state !== 'completed', 'Reset the finished rehearsal first.')
    if (action === 'hazard') s.hazard = true
    if (action === 'gap') { s.connected = false; s.unknown ||= s.state === 'running' }
    s.state = 'held'
  } else if (action === 'clear') {
    require(s.hazard, 'There is no simulated hazard to clear.'); s.hazard = false
  } else if (action === 'restore') {
    require(!s.connected, 'The simulated link is already connected.'); s.connected = true
  } else if (action === 'done' || action === 'not-started') {
    require(s.state === 'held' && s.connected && s.unknown, 'Restore telemetry for an unknown held step before reconciling it.')
    s.unknown = false
    if (action === 'done') s.cursor += 1
    if (s.cursor === s.steps.length) s.state = 'completed'
  } else throw new Error('Unsupported rehearsal action.')
  return s
}

export function mountMissionRehearsal({ root, dialog, readDesign, blocked = () => false }) {
  const el = (id) => root.querySelector(`#mr-${id}`)
  const actions = ['load', 'start', 'next', 'hold', 'hazard', 'clear', 'gap', 'restore', 'done', 'not-started', 'reset']
  let state = null
  const render = (message) => {
    for (const id of actions) el(id).disabled = blocked() || (id !== 'load' && !state)
    el('speed').disabled = blocked() || !state || state.state === 'running'
    if (state) {
      const s = state
      for (const [id, allowed] of Object.entries({ start: ['ready', 'held'].includes(s.state) && !s.hazard && s.connected && !s.unknown, next: s.state === 'running', hold: s.state === 'running', hazard: s.state !== 'completed' && !s.hazard, clear: s.hazard, gap: s.state !== 'completed' && s.connected, restore: !s.connected, done: s.unknown && s.connected, 'not-started': s.unknown && s.connected })) el(id).disabled = blocked() || !allowed
    }
    el('status').textContent = message || (state ? `${state.identity} · ${state.state} · ${state.cursor}/${state.steps.length} steps · ${state.speed} m/s (practice only)${state.hazard ? ' · HAZARD' : ''}${!state.connected ? ' · telemetry missing' : ''}${state.unknown ? ' · current step UNKNOWN; reconcile before resume' : ''}${state.state === 'completed' ? ' · Tabletop sequence finished; no mission outcome was validated.' : ''}` : 'Load the current design to begin. No rehearsal is active.')
    el('progress').value = state?.cursor || 0
    el('progress').max = state?.steps.length || 1
    const document = root.ownerDocument || globalThis.document
    el('steps').replaceChildren(...(state?.steps || []).map((step, index) => {
      const li = document.createElement('li')
      li.textContent = `${index < state.cursor ? 'Completed in practice' : index === state.cursor ? state.unknown ? 'Unknown' : 'Current' : 'Pending'}: ${step}`
      if (index === state.cursor) li.setAttribute('aria-current', 'step')
      return li
    }))
  }
  for (const action of actions) el(action).addEventListener('click', () => {
    if (blocked() || el(action).disabled) return
    try {
      if (action === 'load') { state = createRehearsal(readDesign()); el('speed').value = String(state.speed) }
      else {
        // Validate the visible speed even if a synthetic event bypassed input handling.
        if (action === 'start') state = transitionRehearsal(state, 'speed', Number(el('speed').value))
        state = transitionRehearsal(state, action)
      }
      render()
    } catch (error) { render(error.message) }
  })
  el('speed').addEventListener('input', () => {
    if (!state || blocked()) return
    try { state = transitionRehearsal(state, 'speed', Number(el('speed').value)); render() }
    catch (error) { render(error.message); el('start').disabled = true }
  })
  const pause = () => { if (state?.state === 'running') { state = transitionRehearsal(state, 'hold'); render() } }
  dialog.addEventListener('close', pause)
  dialog.addEventListener('cancel', pause)
  render()
  return { refresh: () => render(), pause, invalidate: () => { state = null; render() } }
}
