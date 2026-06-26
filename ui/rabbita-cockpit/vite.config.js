import { defineConfig } from 'vite'
import rabbita from '@rabbita/vite'

const moonroboHost =
  process.env.VITE_MOONROBO_HOST_URL ??
  process.env.MOONROBO_HOST_URL ??
  'http://127.0.0.1:5290'
const moonclawGateway =
  process.env.VITE_MOONCLAW_GATEWAY_URL ??
  process.env.MOONCLAW_GATEWAY_URL ??
  'http://127.0.0.1:19000'

export default defineConfig({
  build: {
    chunkSizeWarningLimit: 1200,
  },
  server: {
    proxy: {
      '/__moonrobo_health': moonroboHost,
      '/api': moonroboHost,
      '/lepus-project.json': moonroboHost,
      '/v1': moonclawGateway,
    },
  },
  plugins: [rabbita()],
})
