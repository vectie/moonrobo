import '/styles.css'
import '/viewer/urdf-stl-viewer.js'
import { mountDigitalTrials } from './digital-trials.js'

globalThis.__MOONROBO_HOST_URL =
  import.meta.env.VITE_MOONROBO_HOST_URL ||
  globalThis.__MOONROBO_HOST_URL ||
  (globalThis.location?.origin &&
    `${globalThis.location.origin}${import.meta.env.BASE_URL.replace(/\/$/, '')}`) ||
  'http://127.0.0.1:5290'

globalThis.__MOONCLAW_GATEWAY_URL =
  import.meta.env.VITE_MOONCLAW_GATEWAY_URL ||
  globalThis.__MOONCLAW_GATEWAY_URL ||
  'http://127.0.0.1:19000'

mountDigitalTrials({
  root: document.getElementById('digital-trials-panel'),
  dialog: document.getElementById('digital-trials-dialog'),
  launcher: document.getElementById('digital-trials-open'),
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
