import { defineConfig } from 'vite'
import rabbita from '@rabbita/vite'

export default defineConfig({
  build: {
    chunkSizeWarningLimit: 1200,
  },
  plugins: [rabbita()],
})
