import { inspectLearningExperiments } from './learning-experiments.js'
import { assertRobotReplay } from './robot-context.js'

const seconds = value => `${value.toFixed(3)} s`

// The artifact never supplies a fetch URL. Assets are addressed only through the
// selected experiment's sealed, content-addressed asset route.
export function replayAssetUrl(hostUrl, experimentId, geometry) {
  if (!/^[a-f0-9]{64}$/.test(geometry?.sha256 || '')) throw new Error('Replay mesh has no valid content checksum.')
  return `${hostUrl.replace(/\/$/, '')}/api/moondata/learning-experiments/${encodeURIComponent(experimentId)}/replay-assets/${geometry.sha256}`
}

export function replaySampleTimes(clip) {
  return [...new Set(clip.tracks.flatMap(track => track.frames.map(frame => frame.time_s)))].sort((a, b) => a - b)
}

export function adjacentReplayTime(times, time, direction) {
  if (!times.length) return time
  let low = 0, high = times.length
  while (low < high) {
    const middle = (low + high) >>> 1
    if (times[middle] < time) low = middle + 1
    else high = middle
  }
  if (direction < 0) return times[Math.max(0, low - 1)]
  return times[Math.min(times.length - 1, low < times.length && times[low] <= time + 1e-9 ? low + 1 : low)]
}

// Recorded playback and future live inference feed the same viewer.setFrame
// body-pose channel. This controller owns time and selection, never physics.
export function mountLearningReplay({
  root, dialog, embedded = false, hostUrl = '', fetchImpl = globalThis.fetch.bind(globalThis), robotId = '',
  loadViewer = () => import('./viewer/pose-replay-viewer.js'),
  loadChannel = () => import('./viewer/pose-replay-channel.js'),
}) {
  if (!root || (!dialog && !embedded)) return null
  let active = false
  const isVisible = () => embedded ? active : dialog.open
  const document = root.ownerDocument
  const window = document.defaultView
  const existing = root.querySelector('[data-learning-replay]')
  if (existing) return null
  const pane = document.createElement('details')
  pane.className = 'learning-replay'
  pane.dataset.learningReplay = ''
  pane.innerHTML = `<summary>3D experiment replay <span>Recorded robot motion and reference comparison</span></summary>
    <div class="lr-content">
      <p>Choose a registered experiment and an action to inspect its recorded full-body motion.</p>
      <div class="lr-selectors">
        <div class="lr-experiment-field"><label for="lr-experiment">Experiment</label><select id="lr-experiment" disabled aria-describedby="lr-status"><option>Open replay to load experiments</option></select></div>
        <div class="lr-action-field"><label for="lr-action">Action / recorded episode</label><select id="lr-action" disabled><option>Select an experiment first</option></select></div>
        <button id="lr-refresh" type="button">Refresh recordings</button>
      </div>
      <p id="lr-status" class="lr-status" role="status" aria-live="polite" aria-atomic="true">Open replay to load registered experiments.</p>
      <div id="lr-player" hidden>
        <p id="lr-selection" class="lr-selection"></p>
        <div class="lr-stage">
        <div id="lr-viewport" class="lr-viewport" aria-label="Recorded robot pose viewport" aria-describedby="lr-viewport-help"></div>
        <label class="lr-reference-toggle" for="lr-reference"><input id="lr-reference" type="checkbox" ${embedded ? '' : 'checked'} disabled>${embedded ? '参考动作' : 'Compare with reference motion'}</label>
        <p id="lr-render-status" class="lr-render-status" role="status" aria-live="polite"></p>
        <p id="lr-track-status" class="lr-track-status" role="status" aria-live="polite"></p>
        </div>
        <div class="lr-dock">
        <div class="lr-controls">
          <button id="lr-play" type="button" aria-controls="lr-viewport" aria-pressed="false" disabled>Play</button>
          <button id="lr-prev" type="button" disabled>Previous sample</button>
          <button id="lr-next" type="button" disabled>Next sample</button>
          <button id="lr-restart" type="button" disabled>Restart</button>
          <label class="lr-speed" for="lr-speed">Speed <select id="lr-speed"><option value="0.25">0.25×</option><option value="0.5">0.5×</option><option value="1" selected>1×</option><option value="2">2×</option></select></label>
          <button id="lr-fit" type="button" disabled>Fit robot in view</button>
        </div>
        <div class="lr-timeline-heading"><label for="lr-time">Time from episode start</label><output id="lr-clock" for="lr-time">0.000 s / 0.000 s</output></div>
        <input id="lr-time" type="range" min="0" max="0" step="any" value="0" disabled aria-describedby="lr-time-help">
        </div>
        ${embedded ? '<details class="lr-details"><summary>回放详情</summary>' : ''}
        <details><summary>Playback help</summary><p id="lr-time-help" class="lr-help">Drag or click the timeline; use arrow keys or the sample buttons for precise steps. Seeking pauses playback.</p>
        <p id="lr-viewport-help" class="lr-help">Drag the view to orbit; scroll to zoom. Recorded positions and rotations are interpolated between samples. A finished physics track holds its final recorded pose while the reference may continue.</p></details>
        <ul id="lr-legend" class="lr-legend" aria-label="Motion tracks"></ul>
        <details class="lr-provenance"><summary>Recording source</summary><pre id="lr-source"></pre></details>
        ${embedded ? '</details>' : ''}
      </div>
    </div>`
  root.insertBefore(pane, root.querySelector('#le-comparison'))
  const el = name => pane.querySelector(`#lr-${name}`)
  for (const [name, label] of [['play', 'Play'], ['prev', 'Previous sample'], ['next', 'Next sample'], ['restart', 'Restart'], ['fit', 'Fit robot in view']]) el(name).title = label
  const apiUrl = path => `${hostUrl.replace(/\/$/, '')}/api/moondata/learning-experiments${path}`
  const events = new AbortController()
  const listen = (target, name, listener) => target.addEventListener(name, listener, { signal: events.signal })
  let experiments = [], replay = null, clip = null, sampler = null, sampleTimes = []
  let viewer = null, channelModule = null, viewerModule = null, time = 0, playing = false
  let animation = 0, anchorWall = null, anchorTime = 0, listRequest = null, replayRequest = null
  let generation = 0, disposed = false, initialized = false, pending = Promise.resolve()
  let legendRows = [], lastTrackStatus = '', lastAnnouncement = ''

  function setStatus(message, failed = false) {
    pane.dataset.error = String(failed)
    el('status').textContent = embedded ? message
      .replace(/^Paused at (.+)\.$/, '已暂停 · $1')
      .replace(/^Replay finished at (.+)\.$/, '回放结束 · $1')
      .replace(/^Playing .+\.$/, '正在播放') : message
  }
  function setOptions(select, entries, placeholder) {
    select.replaceChildren(...(entries.length ? entries : [{ value: '', label: placeholder }]).map(entry => {
      const option = document.createElement('option')
      option.value = entry.value; option.textContent = entry.label
      return option
    }))
    select.disabled = entries.length === 0
  }
  function announce(message) {
    if (message !== lastAnnouncement) { lastAnnouncement = message; setStatus(message) }
  }
  function pause(announcePause = false) {
    const wasPlaying = playing
    playing = false; anchorWall = null
    if (animation) window.cancelAnimationFrame(animation)
    animation = 0
    el('play').textContent = 'Play'; el('play').title = 'Play'; el('play').setAttribute('aria-pressed', 'false')
    if (announcePause && wasPlaying) announce(`Paused at ${seconds(time)}.`)
  }
  function disposeViewer() {
    const oldViewer = viewer
    viewer = null
    oldViewer?.dispose()
    el('viewport').replaceChildren()
  }
  function clearRecording() {
    pause(); disposeViewer()
    replay = null; clip = null; sampler = null; sampleTimes = []; time = 0
    legendRows = []; lastTrackStatus = ''; lastAnnouncement = ''
    el('player').hidden = true; el('render-status').textContent = ''
    el('track-status').textContent = ''; el('legend').replaceChildren()
    el('source').textContent = ''; el('selection').textContent = ''
    for (const name of ['play', 'prev', 'next', 'restart', 'fit', 'time', 'reference']) el(name).disabled = true
    setOptions(el('action'), [], 'Select an experiment first')
  }
  async function get(path, signal) {
    const response = await fetchImpl(apiUrl(path), { method: 'GET', signal, headers: { Accept: 'application/json' } })
    let payload
    try { payload = await response.json() }
    catch { throw new Error(`The replay service returned an unreadable response (HTTP ${response.status}).`) }
    if (!response.ok) {
      if (response.status === 404 && path.endsWith('/replay')) {
        throw new Error('No full-body 3D recording is registered for this experiment yet. Scalar evaluation metrics alone cannot reconstruct robot motion. Choose another experiment or register a pose recording, then refresh.')
      }
      const reason = typeof payload?.message === 'string' ? ` ${payload.message}` : ''
      throw new Error(`Cannot read the recorded replay (HTTP ${response.status}).${reason} Refresh to retry.`)
    }
    return payload
  }
  function renderTime() {
    if (!sampler || !clip || !viewer) return
    const samples = sampler.sample(time)
    const statuses = []
    for (let index = 0; index < samples.length; index += 1) {
      const sample = samples[index]
      const visible = sample.visible && (sample.kind !== 'reference' || el('reference').checked)
      if (sample.frame) viewer.setFrame(sample.trackId, sample.frame, { kind: sample.kind, visible, ended: sample.ended })
      else viewer.setTrackVisibility(sample.trackId, false)
      const track = clip.tracks.find(value => value.id === sample.trackId)
      const end = track?.frames.at(-1)?.time_s
      const endReason = track?.end_reason || (sample.kind === 'physics' && clip.source?.end_reason)
      const description = sample.state === 'ended' ? `ended at ${seconds(end)}; final pose held${endReason ? ` (${endReason})` : ''}` : sample.state === 'waiting' ? 'waiting for first recorded sample' : 'recorded motion'
      const row = legendRows.find(value => value.id === sample.trackId)
      const status = sample.kind === 'reference' && !el('reference').checked ? 'hidden' : description
      if (row && row.status.textContent !== status) row.status.textContent = status
      if (sample.state === 'ended') statuses.push(embedded ? `${sample.kind === 'physics' ? '仿真' : '参考'}结束于 ${seconds(end)} · 保留末帧` : `${sample.label || sample.trackId}: ${description}.`)
    }
    const nextTrackStatus = statuses.join(' ')
    if (nextTrackStatus !== lastTrackStatus) { lastTrackStatus = nextTrackStatus; el('track-status').textContent = nextTrackStatus }
    el('time').value = String(time)
    el('time').setAttribute('aria-valuetext', `${seconds(time)} / ${seconds(sampler.endTime)}`)
    el('clock').textContent = `${seconds(time)} / ${seconds(sampler.endTime)}`
    el('prev').disabled = time <= sampler.startTime
    el('next').disabled = time >= sampler.endTime
    el('restart').disabled = time <= sampler.startTime && !playing
  }
  function seek(nextTime) {
    if (!sampler || !Number.isFinite(nextTime)) return
    pause()
    time = Math.max(sampler.startTime, Math.min(sampler.endTime, nextTime))
    renderTime(); announce(`Paused at ${seconds(time)}.`)
  }
  function tick(wallTime) {
    animation = 0
    if (!playing || !sampler || !isVisible() || !pane.open || document.hidden) { pause(); return }
    if (anchorWall === null) { anchorWall = wallTime; anchorTime = time }
    time = Math.min(sampler.endTime, anchorTime + ((wallTime - anchorWall) / 1000) * Number(el('speed').value))
    renderTime()
    if (time >= sampler.endTime) { pause(); announce(`Replay finished at ${seconds(time)}.`); return }
    animation = window.requestAnimationFrame(tick)
  }
  function play() {
    if (!sampler || !viewer || sampler.duration <= 0 || !isVisible() || !pane.open || document.hidden) return
    if (playing) { pause(true); return }
    if (time >= sampler.endTime) time = sampler.startTime
    playing = true; anchorWall = null
    el('play').textContent = 'Pause'; el('play').title = 'Pause'; el('play').setAttribute('aria-pressed', 'true')
    announce(`Playing ${clip.label || clip.id}.`)
    animation = window.requestAnimationFrame(tick)
  }
  function selectClip(id) {
    if (!replay || !viewer || !channelModule) return
    const selected = replay.clips.find(value => value.id === id)
    if (!selected) return
    pause(); viewer.clearTracks()
    clip = selected; sampler = channelModule.createReplaySampler(clip); sampleTimes = replaySampleTimes(clip)
    time = sampler.startTime; lastTrackStatus = ''; lastAnnouncement = ''
    el('action').value = clip.id
    el('selection').textContent = `${replay.experiment_id || el('experiment').value} · ${clip.label || clip.id}${Number.isFinite(clip.source_start_time_s) ? ` · reference origin ${seconds(clip.source_start_time_s)}` : ''}`
    el('time').min = String(sampler.startTime); el('time').max = String(sampler.endTime)
    el('time').disabled = sampler.duration <= 0; el('play').disabled = sampler.duration <= 0; el('fit').disabled = false
    el('reference').disabled = !clip.tracks.some(track => track.kind === 'reference')
    legendRows = clip.tracks.map(track => {
      const row = document.createElement('li'), label = document.createElement('strong'), status = document.createElement('span')
      row.className = `lr-track lr-track-${track.kind}`
      label.textContent = track.kind === 'physics' ? 'Physics recording' : 'Reference motion'
      row.append(label, status)
      return { id: track.id, row, status }
    })
    el('legend').replaceChildren(...legendRows.map(value => value.row))
    el('source').textContent = JSON.stringify({ format: replay.format, experiment_id: replay.experiment_id, model: { id: replay.model?.id, sha256: replay.model?.sha256 }, source: replay.source, action: { id: clip.id, source_start_time_s: clip.source_start_time_s, source: clip.source } }, null, 2)
    renderTime(); viewer.fitCamera()
    announce('Recording ready. Press Play to start.')
  }
  async function selectExperiment(id, force = false) {
    if (!force && replay?.experiment_id === id && sampler && viewer) return
    const token = ++generation
    replayRequest?.abort(); replayRequest = new AbortController()
    const request = replayRequest
    clearRecording()
    if (!id) { pane.setAttribute('aria-busy', 'false'); return }
    if (embedded) setOptions(el('experiment'), [{ value: id, label: id }])
    el('experiment').value = id
    setOptions(el('action'), [], 'Loading recorded actions…')
    setStatus('Loading 3D recording…'); pane.setAttribute('aria-busy', 'true')
    try {
      const [payload, channel, renderer] = await Promise.all([get(`/${encodeURIComponent(id)}/replay`, request.signal), loadChannel(), loadViewer()])
      if (disposed || token !== generation) return
      const result = channel.validatePoseReplay(payload)
      if (robotId) assertRobotReplay(result, robotId)
      if (result.experiment_id !== id) throw new Error('This recording belongs to a different experiment. Refresh the registered evidence.')
      if (!result.clips.length) throw new Error('This experiment has no recorded actions with full-body poses.')
      channelModule = channel; viewerModule = renderer; replay = result
      el('player').hidden = false
      const created = viewerModule.createPoseReplayViewer({
        dark: embedded && document.documentElement.dataset.theme !== 'light',
        followTheme: embedded,
        mount: el('viewport'),
        allowedAssetOrigins: [new URL(apiUrl(''), window.location.href).origin],
        resolveAssetUrl: geometry => replayAssetUrl(hostUrl, id, geometry),
        onStatus: status => { if (token === generation && !disposed) { el('render-status').textContent = status.message || ''; el('render-status').dataset.state = status.state } },
      })
      viewer = created
      await created.setModel(replay.model)
      if (disposed || token !== generation) { created.dispose(); return }
      el('viewport').dataset.modelSha256 = replay.model.sha256
      const motionNames = { 'pose-offset': '姿态偏移', 'joint-sines-high': '关节摆动' }
      setOptions(el('action'), replay.clips.map(value => ({ value: value.id, label: (embedded && motionNames[value.source?.reference_id]) || value.label || value.id })))
      selectClip(replay.clips[0].id)
    } catch (error) {
      if (disposed || token !== generation || error.name === 'AbortError') return
      clearRecording(); setOptions(el('action'), [], 'No 3D recording available'); setStatus(error.message, true)
    } finally {
      if (token === generation && !disposed) pane.setAttribute('aria-busy', 'false')
    }
  }
  async function refresh() {
    const selectedId = el('experiment').value
    const token = ++generation
    listRequest?.abort(); replayRequest?.abort(); listRequest = new AbortController()
    const request = listRequest
    clearRecording(); experiments = []
    el('refresh').disabled = true; pane.setAttribute('aria-busy', 'true')
    setOptions(el('experiment'), [], 'Loading registered experiments…'); setStatus('Loading registered experiments…')
    try {
      const payload = await get('', request.signal)
      const result = inspectLearningExperiments(payload)
      if (disposed || token !== generation) return
      initialized = true
      const availableIds = new Set(Array.isArray(payload.replay_experiment_ids) ? payload.replay_experiment_ids.filter(value => typeof value === 'string') : [])
      experiments = result.filter(value => availableIds.has(value.experiment_id)).sort((a, b) => a.experiment_id.localeCompare(b.experiment_id))
      setOptions(el('experiment'), experiments.map(value => ({ value: value.experiment_id, label: value.title || value.experiment_id })), 'No recordings registered')
      if (!experiments.length) { setStatus('No 3D recordings are registered yet.'); return }
      const nextId = experiments.some(value => value.experiment_id === selectedId) ? selectedId : (experiments.find(value => availableIds.has(value.experiment_id)) || experiments[0]).experiment_id
      // Selection is independent of legacy candidate metrics; aligned/native
      // experiments with candidates=[] remain selectable here.
      await selectExperiment(nextId)
    } catch (error) {
      if (disposed || token !== generation || error.name === 'AbortError') return
      setOptions(el('experiment'), [], 'Experiment list unavailable'); setStatus(error.message, true)
    } finally {
      if (!disposed && listRequest === request) {
        el('refresh').disabled = false
        if (token === generation) pane.setAttribute('aria-busy', 'false')
      }
    }
  }
  function startRefresh() { pending = refresh(); return pending }
  function suspend() {
    pause()
    // A hidden dialog must not complete a late fetch into a detached WebGL
    // scene. Loaded recordings stay available for a deliberate reopen.
    if (pane.getAttribute('aria-busy') === 'true') {
      ++generation; listRequest?.abort(); replayRequest?.abort(); clearRecording()
      el('refresh').disabled = false; pane.setAttribute('aria-busy', 'false'); initialized = false
      setStatus('Replay loading paused. Reopen the replay pane or refresh to load the recording.')
    }
  }
  listen(pane, 'toggle', () => {
    if (!pane.open) { suspend(); return }
    if (!embedded && isVisible() && !initialized) startRefresh()
  })
  listen(el('refresh'), 'click', () => {
    pending = embedded ? selectExperiment(el('experiment').value, true) : startRefresh()
  })
  listen(el('experiment'), 'change', () => { pending = selectExperiment(el('experiment').value) })
  listen(el('action'), 'change', () => selectClip(el('action').value))
  listen(el('play'), 'click', play)
  listen(el('prev'), 'click', () => seek(adjacentReplayTime(sampleTimes, time, -1)))
  listen(el('next'), 'click', () => seek(adjacentReplayTime(sampleTimes, time, 1)))
  listen(el('restart'), 'click', () => sampler && seek(sampler.startTime))
  listen(el('time'), 'pointerdown', () => pause(true))
  listen(el('time'), 'input', () => seek(Number(el('time').value)))
  listen(el('time'), 'keydown', event => {
    if (!sampler) return
    const directions = { ArrowLeft: -1, ArrowDown: -1, ArrowRight: 1, ArrowUp: 1 }
    if (event.key in directions) { event.preventDefault(); seek(adjacentReplayTime(sampleTimes, time, directions[event.key])) }
    else if (event.key === 'Home' || event.key === 'End') { event.preventDefault(); seek(event.key === 'Home' ? sampler.startTime : sampler.endTime) }
  })
  listen(el('speed'), 'change', () => { anchorWall = null; anchorTime = time })
  listen(el('reference'), 'change', renderTime)
  listen(el('fit'), 'click', () => viewer?.fitCamera())
  if (dialog) listen(dialog, 'close', suspend)
  listen(document, 'visibilitychange', () => { if (document.hidden) pause(true) })
  const openObserver = new window.MutationObserver(() => {
    if (!isVisible()) suspend()
    else if (pane.open && !initialized) startRefresh()
  })
  if (dialog) openObserver.observe(dialog, { attributes: true, attributeFilter: ['open'] })
  return {
    refresh: startRefresh,
    selectExperiment: id => { pending = selectExperiment(id); return pending },
    setActive(value) { active = value; pane.open = value; if (!value) suspend() },
    selectClip, seek, pause, whenIdle: () => pending,
    dispose() { disposed = true; ++generation; listRequest?.abort(); replayRequest?.abort(); pause(); disposeViewer(); events.abort(); openObserver.disconnect(); pane.remove() },
  }
}
