import { defineConfig, loadEnv } from "vite";
import { e1LivePose } from "./e1/live-server.mjs";

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), "MOONROBO_E1_");
  return {
    server: { host: "127.0.0.1", port: 5300, strictPort: true },
    preview: { host: "127.0.0.1", port: 4300, strictPort: true },
    plugins: [e1LivePose(process.env.MOONROBO_E1_LIVE_FILE ?? env.MOONROBO_E1_LIVE_FILE,
      process.env.MOONROBO_E1_REPLAY_FILE ?? env.MOONROBO_E1_REPLAY_FILE)],
    build: {
      outDir: "dist-e1-live",
      rollupOptions: { input: "e1-live.html" },
    },
  };
});
