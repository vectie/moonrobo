import '/styles.css'
import '/viewer/urdf-stl-viewer.js'

const app = document.getElementById('app')

if (app) {
  app.innerHTML = `
    <div class="boot-shell">
      <div>
        <p class="eyebrow">Moonrobo</p>
        <h1>Loading cockpit</h1>
      </div>
    </div>
  `
}

await import('/main.js')
