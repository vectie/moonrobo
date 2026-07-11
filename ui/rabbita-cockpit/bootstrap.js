import '/styles.css'
import '/viewer/urdf-stl-viewer.js'

globalThis.__MOONROBO_HOST_URL =
  import.meta.env.VITE_MOONROBO_HOST_URL ||
  globalThis.__MOONROBO_HOST_URL ||
  globalThis.location?.origin ||
  'http://127.0.0.1:5290'

globalThis.__MOONCLAW_GATEWAY_URL =
  import.meta.env.VITE_MOONCLAW_GATEWAY_URL ||
  globalThis.__MOONCLAW_GATEWAY_URL ||
  'http://127.0.0.1:19000'

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
