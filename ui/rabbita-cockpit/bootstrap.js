import '/styles.css'
import '/viewer/urdf-stl-viewer.js'
import { mountDigitalTrials } from './digital-trials.js'
import { mountDesignWorkbench } from './design-workbench.js'
import { mountTelemetryReview } from './telemetry-review.js'

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

await import('/main.js')
