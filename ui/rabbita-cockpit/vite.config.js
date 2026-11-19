import { defineConfig, loadEnv } from 'vite'
import rabbita from '@rabbita/vite'
import { localModelData } from './g1/local-data.mjs'
import { e1TrainingStatus } from './e1/status-server.mjs'
import { e1LivePose } from './e1/live-server.mjs'

import { orientationEvidence } from './heldout/orientation-build.js'

const moonroboHost =
  process.env.VITE_MOONROBO_HOST_URL ??
  process.env.MOONROBO_HOST_URL ??
  'http://127.0.0.1:5290'

// Rabbita's resolver refreshes the MoonBit build for every JavaScript import.
// Only our generated entry belongs to that resolver; Three and UI modules
// should use Vite's normal resolution without hundreds of redundant builds.
const cockpit = rabbita({ mainPkgDir: 'main' })
const resolveCockpitEntry = cockpit.resolveId
cockpit.resolveId = function (source, ...args) {
  return source.split('?', 1)[0] === '/main.js'
    ? resolveCockpitEntry.call(this, source, ...args)
    : null
}

export default defineConfig(({ mode }) => {
  const e1Env = loadEnv(mode, process.cwd(), 'MOONROBO_E1_')
  return {
    base: process.env.MOONROBO_PUBLIC_BASE || '/',
    build: {
      chunkSizeWarningLimit: 1200,
      rollupOptions: {
        input: { cockpit: 'index.html', results: 'results.html', g1: 'g1.html', e1: 'e1.html', e1Live: 'e1-live.html', compare: 'compare.html', workflow: 'workflow.html', orientation: 'orientation.html', armIk: 'arm-ik.html' },
      },
    },
    server: {
      proxy: {
        '/__moonrobo_health': moonroboHost,
        '/api': moonroboHost,
        '/lepus-project.json': moonroboHost,
      },
    },
    plugins: [orientationEvidence(), cockpit, localModelData(process.env.MOONROBO_G1_DEMO_ROOT), e1LivePose(e1Env.MOONROBO_E1_LIVE_FILE), e1TrainingStatus({
      host: e1Env.MOONROBO_E1_SSH_HOST,
      socket: e1Env.MOONROBO_E1_SSH_SOCKET,
    })],
  }
})
