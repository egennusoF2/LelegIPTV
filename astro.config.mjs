// @ts-check
import { defineConfig } from "astro/config"
import tailwindcss from "@tailwindcss/vite"
import { optimizeTablerIconsImport } from "./src/plugins/vite-plugin-optimize-tabler-icons.ts"
import { streamProxyPlugin } from "./src/plugins/vite-plugin-stream-proxy.ts"
import svelte from "@astrojs/svelte"

const hmrHost = process.env.XTREAM_HMR_HOST

export default defineConfig({
  devToolbar: {
    enabled: false,
  },
  vite: {
    define: {
      __XT_PLAYBACK_BUILD__: JSON.stringify("2026-06-01-ios-hls"),
    },
    plugins: [tailwindcss(), optimizeTablerIconsImport(), streamProxyPlugin()],
    server: {
      host: "0.0.0.0",
      port: 4321,
      hmr: hmrHost
        ? { host: hmrHost, protocol: "ws", port: 4321 }
        : undefined,
      warmup: {
        clientFiles: [
          "./src/scripts/movies/detail.ts",
          "./src/scripts/series/detail.ts",
          "./src/scripts/lib/player-runtime.ts",
          "./src/components/PlaylistSwitcher.svelte",
        ],
      },
    },
    build: {
      chunkSizeWarningLimit: 800,
    },
    optimizeDeps: {
      include: [
        "@tauri-apps/api/app",
        "@tauri-apps/api/window",
        "@tauri-apps/api/event",
        "@tauri-apps/plugin-process",
        "@tauri-apps/plugin-updater",
        "@tauri-apps/plugin-http",
        "@tauri-apps/plugin-fs",
        "@tauri-apps/plugin-dialog",
        "@tauri-apps/plugin-notification",
        "@tauri-apps/plugin-opener",
        "tauri-plugin-android-fs-api",
        "@tabler/icons-svelte/icons/chevron-down",
        "@tabler/icons-svelte/icons/plus",
        "@tabler/icons-svelte/icons/refresh",
        "artplayer",
        "hls.js",
        "video.js",
      ],
    },
  },

  integrations: [svelte()],
})
