import '/styles.css'
import '/workspace.css'
import { installToolTabs } from './tool-tabs.js'
import '/viewer/urdf-stl-viewer.js'
import { mountDigitalTrials } from './digital-trials.js'
import { mountDesignWorkbench } from './design-workbench.js'
import { mountTelemetryReview } from './telemetry-review.js'
import { mountLearningWorkspace } from './learning-workspace.js'
import { installRobotContext } from './robot-context.js'
import { mountRecordedRobot } from './recorded-robot.js'
import './learning-replay.css'
import './workbench.css'
import './replay-stage.css'
import './moonvis.css'

mountTelemetryReview({
  root: document.getElementById('telemetry-review-panel'),
  dialog: document.getElementById('telemetry-review-dialog'),
  launcher: document.getElementById('telemetry-review-open'),
})

globalThis.__MOONROBO_PUBLIC_BASE = import.meta.env.BASE_URL

globalThis.__MOONROBO_HOST_URL =
  import.meta.env.VITE_MOONROBO_HOST_URL ||
  globalThis.__MOONROBO_HOST_URL ||
  (globalThis.location?.origin &&
    `${globalThis.location.origin}${import.meta.env.BASE_URL.replace(/\/$/, '')}`) ||
  'http://127.0.0.1:5290'

mountDigitalTrials({
  root: document.getElementById('digital-trials-panel'),
  dialog: document.getElementById('digital-trials-dialog'),
  launcher: document.getElementById('digital-trials-open'),
  hostUrl: globalThis.__MOONROBO_HOST_URL,
})

mountDesignWorkbench({
  root: document.getElementById('design-workbench-panel'),
  dialog: document.getElementById('design-workbench-dialog'),
  launcher: document.getElementById('design-workbench-open'),
  hostUrl: globalThis.__MOONROBO_HOST_URL,
})

const app = document.getElementById('app')

if (app) {
  app.innerHTML = `
    <div class="boot-shell">
      <div>
        <p class="eyebrow">MoonRobo</p>
        <h1>Loading cockpit</h1>
      </div>
    </div>
  `
}

const robotRegistry = await installRobotContext({ hostUrl: globalThis.__MOONROBO_HOST_URL })
await import('/main.js')
installToolTabs(document)

mountLearningWorkspace({ app, parking: document.getElementById('learning-workspace-parking'), hostUrl: globalThis.__MOONROBO_HOST_URL })
mountRecordedRobot({ app, parking: document.getElementById('learning-workspace-parking'), registry: robotRegistry, hostUrl: globalThis.__MOONROBO_HOST_URL })

// The MoonBit tabs are rerendered; delegate keyboard and tool navigation.
document.addEventListener('keydown', (event) => {
  const tab = event.target.closest?.('.workspace-tab')
  if (!tab || !['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return
  const tabs = [...tab.closest('[role="tablist"]').querySelectorAll('[role="tab"]')]
  const index = tabs.indexOf(tab)
  const next = event.key === 'Home' ? 0 : event.key === 'End' ? tabs.length - 1
    : (index + (event.key === 'ArrowRight' ? 1 : -1) + tabs.length) % tabs.length
  event.preventDefault()
  tabs[next].focus()
  tabs[next].click()
})

document.addEventListener('click', (event) => {
  const trigger = event.target.closest?.('[data-open-workspace-tool]')
  if (!trigger) return
  const tool = trigger.dataset.openWorkspaceTool
  if (!['design-workbench', 'digital-trials', 'telemetry-review'].includes(tool)) return
  const dialog = document.getElementById(`${tool}-dialog`)
  if (!dialog || dialog.open) return
  dialog.addEventListener('close', () => { if (trigger.isConnected) trigger.focus() }, { once: true })
  document.getElementById(`${tool}-open`)?.click()
})
