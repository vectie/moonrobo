import { createPoseReplayViewer } from './viewer/pose-replay-viewer.js'
import { validatePoseReplay } from './viewer/pose-replay-channel.js'
import { replayAssetUrl } from './learning-replay.js'
import { assertRobotReplay, experimentsForRobot, RECORDED_ROBOT } from './robot-context.js'

// The model tab is another view of the archived robot, never a replacement URDF.
export function mountRecordedRobot({ app, parking, registry, hostUrl = '', fetchImpl = globalThis.fetch.bind(globalThis) }) {
  const document = app.ownerDocument, window = document.defaultView
  const root = document.createElement('section')
  root.className = 'recorded-robot'
  root.innerHTML = '<div class="recorded-robot-viewport" aria-label="Robot model"></div><p class="recorded-robot-status" role="status"></p><button class="recorded-robot-fit icon-action" title="Fit robot in view" aria-label="Fit robot in view"><span class="robo-glyph glyph-focus" aria-hidden="true"></span></button>'
  parking.append(root)
  const viewport = root.querySelector('.recorded-robot-viewport'), status = root.querySelector('[role="status"]')
  let viewer, experimentId = '', preferred = new URLSearchParams(window.location.search).get('experiment'), generation = 0, disposed = false
  async function load() {
    const eligible = experimentsForRobot(registry, RECORDED_ROBOT).filter(value => registry.replay_experiment_ids?.includes(value.experiment_id))
    const id = eligible.find(value => value.experiment_id === preferred)?.experiment_id || eligible[0]?.experiment_id
    if (id && id === experimentId) return
    const token = ++generation
    viewer?.dispose(); viewer = undefined
    delete viewport.dataset.modelSha256
    if (!id) { status.textContent = 'No 3D recordings are registered yet.'; return }
    experimentId = id; status.textContent = 'Loading 3D recording…'
    try {
      const response = await fetchImpl(`${hostUrl.replace(/\/$/, '')}/api/moondata/learning-experiments/${encodeURIComponent(id)}/replay`)
      if (!response.ok) throw new Error('No 3D recording available')
      const replay = assertRobotReplay(validatePoseReplay(await response.json()), RECORDED_ROBOT)
      if (replay.experiment_id !== id) throw new Error('This recording belongs to a different experiment.')
      if (disposed || token !== generation) return
      const track = replay.clips[0]?.tracks.find(value => value.kind === 'physics')
      if (!track) throw new Error('No 3D recording available')
      const created = createPoseReplayViewer({ mount: viewport, followTheme: true,
        dark: document.documentElement.dataset.theme !== 'light',
        allowedAssetOrigins: [new URL(hostUrl || window.location.origin, window.location.href).origin],
        resolveAssetUrl: geometry => replayAssetUrl(hostUrl, id, geometry),
        onStatus: value => { if (token === generation) status.textContent = value.state === 'ready' ? '' : value.message || '' } })
      viewer = created
      await created.setModel(replay.model)
      if (disposed || token !== generation) { created.dispose(); return }
      created.setFrame(track.id, track.frames[0], { kind: 'physics', visible: true })
      created.fitCamera()
      viewport.dataset.modelSha256 = replay.model.sha256
      viewport.dataset.experiment = id
    } catch (error) {
      if (disposed || token !== generation) return
      viewer?.dispose(); viewer = undefined; experimentId = ''
      status.textContent = error.message
    }
  }
  function sync() {
    const slot = app.querySelector('#recorded-robot-slot')
    const destination = slot || parking
    if (root.parentNode === destination) return
    destination.append(root)
    if (slot) { window.scrollTo(0, 0); void load() }
  }
  const observer = new window.MutationObserver(sync)
  observer.observe(app, { childList: true, subtree: true })
  const select = event => { preferred = event.detail?.experimentId; if (app.querySelector('#recorded-robot-slot')) void load() }
  window.addEventListener('moonrobo:experiment-selected', select)
  root.querySelector('button').addEventListener('click', () => viewer?.fitCamera())
  sync()
  return { dispose() { disposed = true; ++generation; observer.disconnect(); window.removeEventListener('moonrobo:experiment-selected', select); viewer?.dispose(); root.remove() } }
}
