import { defineConfig } from 'vite'
import rabbita from '@rabbita/vite'

const moonroboHost =
  process.env.VITE_MOONROBO_HOST_URL ??
  process.env.MOONROBO_HOST_URL ??
  'http://127.0.0.1:5290'

export default defineConfig({
  base: process.env.MOONROBO_PUBLIC_BASE || '/',
  build: {
    chunkSizeWarningLimit: 1200,
  },
  server: {
    proxy: {
      '/__moonrobo_health': moonroboHost,
      '/api': moonroboHost,
      '/lepus-project.json': moonroboHost,
    },
  },
  plugins: [rabbita({ mainPkgDir: 'main' })],
})
